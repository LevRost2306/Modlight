//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

// ============================================================
// MoonlightTextField — кастомный UITextField для перехвата Backspace
// (оставлен на случай использования в других файлах)
// ============================================================
@protocol MoonlightKeyboardDelegate <NSObject>
- (void)moonlightBackspacePressed;
@end

@interface MoonlightTextField : UITextField
@property (nonatomic, weak) id<MoonlightKeyboardDelegate> mlDelegate;
@end

@implementation MoonlightTextField
- (void)deleteBackward {
    [super deleteBackward];
    if (self.mlDelegate) {
        [self.mlDelegate moonlightBackspacePressed];
    }
}
@end

// ============================================================
// StreamFrameViewController
// ============================================================
@interface StreamFrameViewController () <UIKeyInput>
@end

// В блоке ivar (в фигурных скобках после @implementation)
@implementation StreamFrameViewController
{
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    NSTimer *_inactivityTimer;
    UITextView *_overlayView;
    StreamView *_streamView;
    NSOperationQueue *_opQueue;
    BOOL _userIsInteracting;
    UIView *_joystick;
    BOOL _keyboardVisible;
    BOOL _wantsKeyboard;
    UILabel *_batteryLabel;
    NSTimer *_batteryTimer;
    BOOL _isPortrait;// ← НОВЫЙ ФЛАГ
}

// ==============================
// УБРАН @synthesize hasText — он конфликтовал с методом -(BOOL)hasText
// и вызывал крэш на iOS 8
// ==============================

#pragma mark - View Lifecycle

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif

- (void)viewDidLoad
{
    [super viewDidLoad];

    _wantsKeyboard = NO;
    _keyboardVisible = NO;

    [self.navigationController setNavigationBarHidden:YES animated:YES];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    // Эти элементы из storyboard — НЕ скрываем, они нужны при загрузке
    self.stageLabel.hidden = YES;
    self.spinner.hidden = YES;
    self.tipLabel.hidden = YES;

    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig
                                                  presenceDelegate:self];
    _inactivityTimer = nil;

    // --- ScrollView и StreamView ---
    CGRect screenRect = [[UIScreen mainScreen] bounds];

    _screenScrollView = [[UIScrollView alloc] initWithFrame:screenRect];
    _screenScrollView.contentSize = CGSizeMake(1024, 1200);
    _screenScrollView.scrollEnabled = NO;
    _screenScrollView.backgroundColor = [UIColor blackColor];
    
    // ВАЖНО: вставляем скролл ПОД элементы storyboard, а не поверх!
    [self.view insertSubview:_screenScrollView atIndex:0];

    _streamView = [[StreamView alloc] initWithFrame:CGRectMake(0, 0, 1024, 768)];
    [_streamView setupStreamView:_controllerSupport
                   swipeDelegate:self
             interactionDelegate:self
                          config:self.streamConfig];
    [_screenScrollView addSubview:_streamView];

    // --- Уведомления клавиатуры ---
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

#if !TARGET_OS_TV
    UITapGestureRecognizer *threeFingerTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(toggleKeyboardForced)];
    threeFingerTap.numberOfTouchesRequired = 3;
    [_screenScrollView addGestureRecognizer:threeFingerTap];

    [self setupPanJoystick];
#endif

    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];

    _opQueue = [[NSOperationQueue alloc] init];
    [_opQueue addOperation:_streamMan];

    // --- Уведомления жизненного цикла ---
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    _isPortrait = NO;
    
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [self setupBatteryIndicator];
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    if (parent == nil) {
        [_batteryTimer invalidate];
        _batteryTimer = nil;
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:NO];
        
        if (_isPortrait) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                LiSendKeyboardEvent(0xA2, KEY_ACTION_DOWN, 0);
                LiSendKeyboardEvent(0xA4, KEY_ACTION_DOWN, MODIFIER_CTRL);
                LiSendKeyboardEvent(0x30, KEY_ACTION_DOWN, MODIFIER_CTRL | MODIFIER_ALT);
                usleep(50 * 1000);
                LiSendKeyboardEvent(0x30, KEY_ACTION_UP, MODIFIER_CTRL | MODIFIER_ALT);
                LiSendKeyboardEvent(0xA4, KEY_ACTION_UP, MODIFIER_CTRL);
                LiSendKeyboardEvent(0xA2, KEY_ACTION_UP, 0);
            });
        }
        
        [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
        
        _wantsKeyboard = NO;
        if ([self isFirstResponder]) {
            [self resignFirstResponder];
        }
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        [_opQueue cancelAllOperations];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#pragma mark - Overlay

- (void)updateOverlayText:(NSString *)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        [_overlayView setTextAlignment:NSTextAlignmentCenter];
        [_overlayView setTextColor:[OSColor lightGrayColor]];
        [_overlayView setBackgroundColor:[OSColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }

    if (text != nil) {
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2,
                                            _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    } else {
        [_overlayView setHidden:YES];
    }
}

#pragma mark - Navigation

- (void)returnToMainFrame {
    _wantsKeyboard = NO;
    if ([self isFirstResponder]) {
        [self resignFirstResponder];
    }
    [self.navigationController popToRootViewControllerAnimated:YES];
}

#pragma mark - App Lifecycle

- (void)applicationWillResignActive:(NSNotification *)notification {
    // Отменяем старый таймер если был
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

#if TARGET_OS_TV
    Log(LOG_I, @"Terminating stream after resigning active");
    [self returnToMainFrame];
#else
    // НЕ ставим таймер на отключение — стрим продолжает работать в фоне
    Log(LOG_I, @"App resigned active — keeping stream alive for background audio");
#endif
}

- (void)inactiveTimerExpired:(NSTimer *)timer {
    Log(LOG_I, @"Terminating stream after inactivity");
    [self returnToMainFrame];
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// applicationDidEnterBackground УДАЛЁН — больше не убиваем стрим при уходе в фон

#pragma mark - Stream Callbacks

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    [self returnToMainFrame];
}

- (void)connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.stageLabel.hidden = YES;
        self.tipLabel.hidden = YES;
        self.spinner.hidden = YES;           // ← ДОБАВИТЬ
        [self.spinner stopAnimating];        // ← ДОБАВИТЬ
        
        [self->_streamView showOnScreenControls];
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);

    unsigned int portTestResults = LiTestClientConnectivity(
        CONN_TEST_SERVER, 443,
        LiGetPortFlagsFromTerminationErrorCode(errorCode));

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;

        NSString *title;
        NSString *message;

        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. "
                       "Streaming may not work while connected to this network.";
        } else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;

                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host. "
                               "Check the host PC's firewall and port forwarding rules.";
                    break;

                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. "
                               "Reduce your video bitrate setting or try a faster connection.";
                    break;

                default:
                    title = @"Connection Terminated";
                    message = @"The connection was terminated";
                    break;
            }
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void)stageStarting:(const char *)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString *titleCase = [[[lowerCase substringToIndex:1] uppercaseString]
                               stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self.stageLabel setText:titleCase];
        [self.stageLabel sizeToFit];
        self.stageLabel.center = CGPointMake(self.view.frame.size.width / 2,
                                             self.stageLabel.center.y);
    });
}

- (void)stageComplete:(const char *)stageName {
}

- (void)stageFailed:(const char *)stageName
          withError:(int)errorCode
      portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);

    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;

        NSString *message = [NSString stringWithFormat:@"%s failed with error %d",
                             stageName, errorCode];
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:
                @"\n\nYour device's network connection is blocking Moonlight. "
                 "Streaming may not work while connected to this network."];
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void)launchFailed:(NSString *)message {
    Log(LOG_I, @"Launch failed: %@", message);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Connection Error"
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber
  lowFreqMotor:(unsigned short)lowFreqMotor
 highFreqMotor:(unsigned short)highFreqMotor {
    [_controllerSupport rumble:controllerNumber
                  lowFreqMotor:lowFreqMotor
                 highFreqMotor:highFreqMotor];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;

            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                } else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

#pragma mark - Gamepad & Interaction

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionBegan {
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        !_userIsInteracting) {
        return YES;
    }
    return NO;
}
#endif

#pragma mark - Joystick

- (void)setupPanJoystick {
    _joystick = [[UIView alloc] initWithFrame:CGRectMake(40,
                                                         self.view.bounds.size.height - 100,
                                                         60, 60)];
    _joystick.backgroundColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.5];
    _joystick.layer.cornerRadius = 30;
    _joystick.layer.borderWidth = 2;
    _joystick.layer.borderColor = [UIColor whiteColor].CGColor;
    _joystick.userInteractionEnabled = YES;
    _joystick.alpha = 0.0; // Скрыт по умолчанию, показывается при появлении клавиатуры

    UILabel *arrow = [[UILabel alloc] initWithFrame:_joystick.bounds];
    arrow.text = @"✥";
    arrow.textAlignment = NSTextAlignmentCenter;
    arrow.textColor = [UIColor whiteColor];
    [_joystick addSubview:arrow];

    // Жест для скролла картинки
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleJoystickPan:)];
    [_screenScrollView.panGestureRecognizer requireGestureRecognizerToFail:pan];
    [_joystick addGestureRecognizer:pan];

    // Жест для перемещения самой кнопки
    UILongPressGestureRecognizer *moveGesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleJoystickMove:)];
    moveGesture.minimumPressDuration = 0.3;
    [moveGesture setDelaysTouchesBegan:YES];
    [_joystick addGestureRecognizer:moveGesture];

    [self.view addSubview:_joystick];
}

- (void)handleJoystickPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:gesture.view];
    CGPoint offset = _screenScrollView.contentOffset;

    float newY = offset.y - (translation.y * 1.3);
    float maxOffsetY = _screenScrollView.contentSize.height - _screenScrollView.bounds.size.height;
    if (maxOffsetY <= 0) maxOffsetY = 450.0;

    _screenScrollView.contentOffset = CGPointMake(0, fmax(0, fmin(newY, maxOffsetY)));
    [gesture setTranslation:CGPointZero inView:gesture.view];
}

- (void)handleJoystickMove:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint location = [gesture locationInView:self.view];
        _joystick.center = location;
    }
}

#pragma mark - Keyboard Toggle

// Тройной тап — теперь управляет флагом
- (void)toggleKeyboardForced {
    if (_wantsKeyboard && [self isFirstResponder]) {
        // Прячем клавиатуру
        _wantsKeyboard = NO;
        [self resignFirstResponder];
    } else {
        // Показываем клавиатуру
        _wantsKeyboard = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self becomeFirstResponder];
        });
    }
}

- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardVisible = YES;

    NSDictionary *userInfo = [notification userInfo];
    CGRect kbFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];

    // На iOS 8 в ландшафте width и height могут быть инвертированы
    CGFloat keyboardHeight = MIN(kbFrame.size.width, kbFrame.size.height);

    [UIView animateWithDuration:0.3 animations:^{
        // Показываем джойстик
        self->_joystick.alpha = 1.0;

        // Поднимаем джойстик над клавиатурой
        CGRect frame = self->_joystick.frame;
        frame.origin.y = self.view.bounds.size.height - keyboardHeight - frame.size.height - 10;
        self->_joystick.frame = frame;

        // Настраиваем скролл
        UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, keyboardHeight + 50, 0);
        self->_screenScrollView.contentInset = insets;
        self->_screenScrollView.scrollIndicatorInsets = insets;
    }];
}

// Когда клавиатура скрылась — сбрасываем флаг
- (void)keyboardWillHide:(NSNotification *)notification {
    _keyboardVisible = NO;
    _wantsKeyboard = NO;  // ← Сбрасываем чтобы система не показала снова

    [UIView animateWithDuration:0.3 animations:^{
        self->_joystick.alpha = 0.0;

        self->_screenScrollView.contentInset = UIEdgeInsetsZero;
        self->_screenScrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
        [self->_screenScrollView setContentOffset:CGPointZero animated:YES];

        CGRect frame = self->_joystick.frame;
        frame.origin.y = self.view.bounds.size.height - frame.size.height - 20;
        self->_joystick.frame = frame;
    }];
}

#pragma mark - UIKeyInput

- (BOOL)canBecomeFirstResponder {
    return _wantsKeyboard;
}

- (BOOL)hasText {
    return YES;
}

- (void)insertText:(NSString *)text {
    if (text == nil || text.length == 0) return;

    if ([text isEqualToString:@"\n"]) {
        [self sendKeyEvent:0x0D];
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        const char *utf8 = [text UTF8String];
        if (utf8) {
            LiSendUtf8Text(utf8);
        }
    });
}

- (void)deleteBackward {
    [self sendKeyEvent:0x08];
}

- (void)sendKeyEvent:(short)vkCode {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        LiSendKeyboardEvent(vkCode, KEY_ACTION_DOWN, 0);
        usleep(20 * 1000);
        LiSendKeyboardEvent(vkCode, KEY_ACTION_UP, 0);
    });
}

#pragma mark - UITextInputTraits

- (UIKeyboardType)keyboardType {
    return UIKeyboardTypeDefault;
}

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

- (UIKeyboardAppearance)keyboardAppearance {
    return UIKeyboardAppearanceDark;  // ← ДОБАВИТЬ
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

- (UIReturnKeyType)returnKeyType {
    return UIReturnKeyDefault;
}

- (BOOL)isSecureTextEntry {
    return NO;
}

- (BOOL)enablesReturnKeyAutomatically {
    return NO;
}

#pragma mark - Screen Rotation

- (void)orientationDidChange:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    
    if (orientation == UIDeviceOrientationFaceUp ||
        orientation == UIDeviceOrientationFaceDown ||
        orientation == UIDeviceOrientationUnknown) {
        return;
    }
    
    BOOL wantsPortrait = UIDeviceOrientationIsPortrait(orientation);
    if (wantsPortrait == _isPortrait) return;
    _isPortrait = wantsPortrait;
    
    if (wantsPortrait) {
        NSLog(@"[Rotation] -> Portrait");
        [self rotateAndReconnectPortrait:YES];
    } else {
        NSLog(@"[Rotation] -> Landscape");
        [self rotateAndReconnectPortrait:NO];
    }
}

- (void)rotateAndReconnectPortrait:(BOOL)portrait {
    // 1. Отправляем горячую клавишу для поворота Windows
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        short keyCode = portrait ? 0x39 : 0x30; // 9 или 0
        
        LiSendKeyboardEvent(0xA2, KEY_ACTION_DOWN, 0);                            // Ctrl
        LiSendKeyboardEvent(0xA4, KEY_ACTION_DOWN, MODIFIER_CTRL);                // Alt
        LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, MODIFIER_CTRL | MODIFIER_ALT);
        usleep(50 * 1000);
        LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, MODIFIER_CTRL | MODIFIER_ALT);
        LiSendKeyboardEvent(0xA4, KEY_ACTION_UP, MODIFIER_CTRL);
        LiSendKeyboardEvent(0xA2, KEY_ACTION_UP, 0);
    });
    
    // 2. Ждём поворота Windows, потом переподключаемся с новым разрешением
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (portrait) {
            [self reconnectWithWidth:768 height:1024];
        } else {
            [self reconnectWithWidth:1024 height:768];
        }
    });
}

- (void)reconnectWithWidth:(int)width height:(int)height {
    NSLog(@"[Rotation] Stopping old stream for %dx%d", width, height);
    
    // 1. Останавливаем стрим
    if (_streamMan) {
        [_streamMan stopStream];
        _streamMan = nil;
    }
    [_opQueue cancelAllOperations];
    
    // 2. Обновляем layout сразу
    CGRect screenRect = [[UIScreen mainScreen] bounds];
    CGFloat screenW = screenRect.size.width;
    CGFloat screenH = screenRect.size.height;
    
    // iOS 8: bounds может не переворачиваться
    if (height > width && screenW > screenH) {
        CGFloat t = screenW; screenW = screenH; screenH = t;
    } else if (width > height && screenH > screenW) {
        CGFloat t = screenW; screenW = screenH; screenH = t;
    }
    
    _screenScrollView.frame = CGRectMake(0, 0, screenW, screenH);
    _streamView.frame = CGRectMake(0, 0, screenW, screenH);
    _screenScrollView.contentSize = CGSizeMake(screenW, screenH + 400);
    _screenScrollView.contentOffset = CGPointZero;
    
    // 3. Переподключаемся с задержкой
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.streamConfig.width = width;
        self.streamConfig.height = height;
        
        self->_streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                                      renderView:self->_streamView
                                             connectionCallbacks:self];
        
        self->_opQueue = [[NSOperationQueue alloc] init];
        [self->_opQueue addOperation:self->_streamMan];
        
        NSLog(@"[Rotation] New stream started at %dx%d", width, height);
    });
}

#pragma mark - Battery Indicator

- (void)setupBatteryIndicator {
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    
    _batteryLabel = [[UILabel alloc] init];
    _batteryLabel.font = [UIFont systemFontOfSize:12];
    _batteryLabel.textColor = [UIColor whiteColor];
    _batteryLabel.textAlignment = NSTextAlignmentRight;
    
    // Убираем фон и скругление
    _batteryLabel.backgroundColor = [UIColor clearColor];
    
    // Добавляем легкую тень, чтобы белый текст не терялся на светлом фоне
    _batteryLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    _batteryLabel.shadowOffset = CGSizeMake(0, 1);
    
    // Увеличиваем ширину, чтобы (chg) точно влезало
    _batteryLabel.frame = CGRectMake(self.view.bounds.size.width - 110, 5, 100, 20);
    _batteryLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    
    [self.view addSubview:_batteryLabel];

    // Подписываемся на системные события вместо таймера
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBatteryLevel)
                                                 name:UIDeviceBatteryLevelDidChangeNotification
                                               object:nil];
                                               
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBatteryLevel)
                                                 name:UIDeviceBatteryStateDidChangeNotification
                                               object:nil];
    
    [self updateBatteryLevel];
}

- (void)updateBatteryLevel {
    float level = [[UIDevice currentDevice] batteryLevel];
    if (level < 0.0f) {
        _batteryLabel.text = @"---%";
        return;
    }

    int percent = (int)roundf(level * 100.0f);
    UIDeviceBatteryState state = [[UIDevice currentDevice] batteryState];
    
    if (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull) {
        // Теперь точно влезет в ширину 100
        _batteryLabel.text = [NSString stringWithFormat:@"%d%% (chg)", percent];
    } else {
        _batteryLabel.text = [NSString stringWithFormat:@"%d%%", percent];
    }
}

#if !TARGET_OS_TV
- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
}
#endif

@end

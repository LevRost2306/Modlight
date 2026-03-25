 //
//  StreamView.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamView.h"
#include <Limelight.h>
#import "DataManager.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"
#import <AVFoundation/AVFoundation.h>

static const double X1_MOUSE_SPEED_DIVISOR = 2.5;
static const int REFERENCE_WIDTH = 1280;
static const int REFERENCE_HEIGHT = 720;
static float accumulatedScrollY = 0.0f;
BOOL _tabletMode;
NSMutableDictionary *_activeTouches;
uint32_t _nextPointerId;
static float accumulatedScrollY;

@implementation StreamView {
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    OnScreenControls* onScreenControls;
    
    BOOL isInputingText;
    BOOL isDragging;
    NSTimer* dragTimer;
    
    float streamAspectRatio;
    
    // iOS 13.4 mouse support
    NSInteger lastMouseButtonMask;
    float lastMouseX;
    float lastMouseY;
    
    // Citrix X1 mouse support
    X1Mouse* x1mouse;
    double accumulatedMouseDeltaX;
    double accumulatedMouseDeltaY;
    
#if TARGET_OS_TV
    UIGestureRecognizer* remotePressRecognizer;
    UIGestureRecognizer* remoteLongPressRecognizer;
#endif
    
    id<UserInteractionDelegate> interactionDelegate;
    NSTimer* interactionTimer;
    BOOL hasUserInteracted;
    
    NSDictionary<NSString *, NSNumber *> *dictCodes;
}

// 1. Метод настройки стрима (тот, что ты искал)
- (void) setupStreamView:(ControllerSupport*)controllerSupport
           swipeDelegate:(id<EdgeDetectionDelegate>)swipeDelegate
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig {
    
    self->interactionDelegate = interactionDelegate;
    self->streamAspectRatio = (float)streamConfig.width / (float)streamConfig.height;
    
    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];
    
#if TARGET_OS_TV
    // Код специально для Apple TV
    remotePressRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonPressed:)];
    remotePressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    remoteLongPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonLongPressed:)];
    remoteLongPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    [self addGestureRecognizer:remotePressRecognizer];
    [self addGestureRecognizer:remoteLongPressRecognizer];
#else
    // Код для iPhone/iPad (Экранные кнопки)
    onScreenControls = [[OnScreenControls alloc] initWithView:self controllerSup:controllerSupport swipeDelegate:swipeDelegate];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    if (level == OnScreenControlsLevelAuto) {
        [controllerSupport initAutoOnScreenControlMode:onScreenControls];
    }
    else {
        [onScreenControls setLevel:level];
    }
    
    if (@available(iOS 13.4, *)) {
        [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
        
        UIPanGestureRecognizer *mouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMoved:)];
        mouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
        mouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:mouseWheelRecognizer];
    }
#endif
    
    x1mouse = [[X1Mouse alloc] init];
    x1mouse.delegate = self;
    
    if (settings.btMouseSupport) {
        [x1mouse start];
    }
    _tabletMode = YES;  // Включен по умолчанию
    _activeTouches = [[NSMutableDictionary alloc] init];
    _nextPointerId = 0;
    accumulatedScrollY = 0.0f;
    
    self.multipleTouchEnabled = YES;  // Важно для мультитача!
}

// 2. Стандартные методы инициализации
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) { [self setupCommon]; }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { [self setupCommon]; }
    return self;
}

- (void)setupCommon {
    accumulatedMouseDeltaX = 0;
    accumulatedMouseDeltaY = 0;
    isInputingText = NO;
    isDragging = NO;
}

- (BOOL)canResignFirstResponder {
    return YES;
}

 - (void)startInteractionTimer {

    // Restart user interaction tracking

    hasUserInteracted = NO;

    

    BOOL timerAlreadyRunning = interactionTimer != nil;

    

    // Start/restart the timer

    [interactionTimer invalidate];

    interactionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0

                                                        target:self

                                                      selector:@selector(interactionTimerExpired:)

                                                      userInfo:nil

                                                       repeats:NO];

    

    // Notify the delegate if this was a new user interaction

    if (!timerAlreadyRunning) {

        [interactionDelegate userInteractionBegan];

    }

}


- (void)interactionTimerExpired:(NSTimer *)timer {

    if (!hasUserInteracted) {

        // User has finished touching the screen

        interactionTimer = nil;

        [interactionDelegate userInteractionEnded];

    }

    else {

        // User is still touching the screen. Restart the timer.

        [self startInteractionTimer];

    }

}


- (void) showOnScreenControls {

#if !TARGET_OS_TV

    [onScreenControls show];

    //[self becomeFirstResponder];

#endif

}


- (OnScreenControlsLevel) getCurrentOscState {

    if (onScreenControls == nil) {

        return OnScreenControlsLevelOff;

    }

    else {

        return [onScreenControls getLevel];

    }

}


- (BOOL)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {

    // Movements of greater than 5 pixels are considered confirmed

    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 5;

}


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        UITouch *touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            [self updateCursorLocation:[touch locationInView:self]];
            return;
        }
    }
#endif
    
    if ([self handleMouseButtonEvent:BUTTON_ACTION_PRESS
                          forTouches:touches
                           withEvent:event]) {
        return;
    }
    
    [self startInteractionTimer];
    hasUserInteracted = YES;
    
    if (![onScreenControls handleTouchDownEvent:touches]) {
        if (_tabletMode) {
            // Tablet mode: отправляем настоящие тач-события
            for (UITouch *touch in touches) {
                [self sendTouchEvent:LI_TOUCH_EVENT_DOWN forTouch:touch];
            }
        } else {
            // Mouse mode: старое поведение
            UITouch *touch = [[event allTouches] anyObject];
            originalLocation = touchLocation = [touch locationInView:self];
            LiSendMousePositionEvent(touchLocation.x, touchLocation.y,
                                     self.bounds.size.width, self.bounds.size.height);
            touchMoved = false;
            if ([[event allTouches] count] == 1 && !isDragging) {
                dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                             target:self
                                                           selector:@selector(onDragStart:)
                                                           userInfo:nil
                                                            repeats:NO];
            }
        }
    }
}

- (void)onDragStart:(NSTimer*)timer {

    if (!touchMoved && !isDragging){

        isDragging = true;

        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);

    }

}


- (BOOL)handleMouseButtonEvent:(int)buttonAction forTouches:(NSSet *)touches withEvent:(UIEvent *)event {

#if !TARGET_OS_TV

    if (@available(iOS 13.4, *)) {

        UITouch* touch = [touches anyObject];

        if (touch.type == UITouchTypeIndirectPointer) {

            UIEventButtonMask changedButtons = lastMouseButtonMask ^ event.buttonMask;

            

            for (int i = BUTTON_LEFT; i <= BUTTON_X2; i++) {

                UIEventButtonMask buttonFlag;

                

                switch (i) {

                        // Right and Middle are reversed from what iOS uses

                    case BUTTON_RIGHT:

                        buttonFlag = UIEventButtonMaskForButtonNumber(2);

                        break;

                    case BUTTON_MIDDLE:

                        buttonFlag = UIEventButtonMaskForButtonNumber(3);

                        break;

                        

                    default:

                        buttonFlag = UIEventButtonMaskForButtonNumber(i);

                        break;

                }

                

                if (changedButtons & buttonFlag) {

                    LiSendMouseButtonEvent(buttonAction, i);

                }

            }

            

            lastMouseButtonMask = event.buttonMask;

            return YES;

        }

    }

#endif

    

    return NO;

}


- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        UITouch *touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            [self updateCursorLocation:[touch locationInView:self]];
            return;
        }
    }
#endif
    
    hasUserInteracted = YES;
    
    if (![onScreenControls handleTouchMovedEvent:touches]) {
        if (_tabletMode) {
            // Tablet mode: отправляем движение всех пальцев
            for (UITouch *touch in touches) {
                [self sendTouchEvent:LI_TOUCH_EVENT_MOVE forTouch:touch];
            }
        } else {
            // Mouse mode: старое поведение
            if ([[event allTouches] count] == 1) {
                UITouch *touch = [[event allTouches] anyObject];
                CGPoint currentLocation = [touch locationInView:self];
                LiSendMousePositionEvent(currentLocation.x, currentLocation.y,
                                         self.bounds.size.width, self.bounds.size.height);
                touchLocation = currentLocation;
                if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                    touchMoved = true;
                }
            } else if ([[event allTouches] count] == 2) {
                CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:self];
                CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:self];
                CGPoint avgLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2,
                                                  (firstLocation.y + secondLocation.y) / 2);
                if (touchLocation.y != avgLocation.y) {
                    accumulatedScrollY += (avgLocation.y - touchLocation.y);
                    int scrollClicks = (int)(accumulatedScrollY / 15.0f);
                    if (scrollClicks != 0) {
                        LiSendScrollEvent(scrollClicks);
                        accumulatedScrollY -= scrollClicks * 15.0f;
                    }
                }
                if ([self isConfirmedMove:firstLocation from:originalLocation]) {
                    touchMoved = true;
                }
                touchLocation = avgLocation;
            }
        }
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {

    BOOL handled = NO;

    

    if (@available(iOS 13.4, tvOS 13.4, *)) {

        for (UIPress* press in presses) {

            // For now, we'll treated it as handled if we handle at least one of the

            // UIPress events inside the set.

            if (press.key != nil && [KeyboardSupport sendKeyEvent:press.key down:YES]) {

                // This will prevent the legacy UITextField from receiving the event

                handled = YES;

            }

        }

    }

    

    if (!handled) {

        [super pressesBegan:presses withEvent:event];

    }

}


- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {

    BOOL handled = NO;

    

    if (@available(iOS 13.4, tvOS 13.4, *)) {

        for (UIPress* press in presses) {

            // For now, we'll treated it as handled if we handle at least one of the

            // UIPress events inside the set.

            if (press.key != nil && [KeyboardSupport sendKeyEvent:press.key down:NO]) {

                // This will prevent the legacy UITextField from receiving the event

                handled = YES;

            }

        }

    }

    

    if (!handled) {

        [super pressesEnded:presses withEvent:event];

    }

}


- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                          forTouches:touches
                           withEvent:event]) {
        return;
    }
    
    hasUserInteracted = YES;
    
    if (![onScreenControls handleTouchUpEvent:touches]) {
        if (_tabletMode) {
            // Tablet mode: отправляем отпускание всех пальцев
            for (UITouch *touch in touches) {
                [self sendTouchEvent:LI_TOUCH_EVENT_UP forTouch:touch];
            }
        } else {
            // Mouse mode: старое поведение
            accumulatedScrollY = 0.0f;
            [dragTimer invalidate];
            dragTimer = nil;
            
            if (isDragging) {
                isDragging = false;
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            } else if (!touchMoved) {
                if ([[event allTouches] count] == 2) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
                        usleep(100 * 1000);
                        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                    });
                } else if ([[event allTouches] count] == 1) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                        if (!self->isDragging) {
                            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                            usleep(100 * 1000);
                        }
                        self->isDragging = false;
                        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                    });
                }
            }
            
            if ([[event allTouches] count] - [touches count] == 1) {
                NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
                [activeSet unionSet:[event allTouches]];
                [activeSet minusSet:touches];
                touchLocation = [[activeSet anyObject] locationInView:self];
                touchMoved = true;
            }
        }
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_tabletMode) {
        for (UITouch *touch in touches) {
            [self sendTouchEvent:LI_TOUCH_EVENT_CANCEL forTouch:touch];
        }
    } else {
        // В mouse mode просто сбрасываем состояние
        accumulatedScrollY = 0.0f;
        [dragTimer invalidate];
        dragTimer = nil;
        if (isDragging) {
            isDragging = false;
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        }
    }
}

#if TARGET_OS_TV

- (void)remoteButtonPressed:(id)sender {

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        Log(LOG_D, @"Sending left mouse button press");

        

        // Mark this as touchMoved to avoid a duplicate press on touch up

        self->touchMoved = true;

        

        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);

        

        // Wait 100 ms to simulate a real button press

        usleep(100 * 1000);

        

        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);

    });

}

- (void)remoteButtonLongPressed:(id)sender {

    Log(LOG_D, @"Holding left mouse button");

    

    isDragging = true;

    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);

}

#else

- (void) updateCursorLocation:(CGPoint)location {

    // These are now relative to the StreamView, however we need to scale them

    // further to make them relative to the actual video portion.

    float x = location.x - self.bounds.origin.x;

    float y = location.y - self.bounds.origin.y;

    

    // For some reason, we don't seem to always get to the bounds of the window

    // so we'll subtract 1 pixel if we're to the left/below of the origin and

    // and add 1 pixel if we're to the right/above. It should be imperceptible

    // to the user but it will allow activation of gestures that require contact

    // with the edge of the screen (like Aero Snap).

    if (x < self.bounds.size.width / 2) {

        x--;

    }

    else {

        x++;

    }

    if (y < self.bounds.size.height / 2) {

        y--;

    }

    else {

        y++;

    }

    

    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect

    CGSize videoSize;

    CGPoint videoOrigin;

    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {

        videoSize = CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);

    } else {

        videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);

    }

    videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,

                              self.bounds.size.height / 2 - videoSize.height / 2);

    

    // Confine the cursor to the video region. We don't just discard events outside

    // the region because we won't always get one exactly when the mouse leaves the region.

    x = MIN(MAX(x, videoOrigin.x), videoOrigin.x + videoSize.width);

    y = MIN(MAX(y, videoOrigin.y), videoOrigin.y + videoSize.height);

    

    // Send the mouse position relative to the video region if it has changed

    //

    // NB: It is important for functionality (not just optimization) to only

    // send it if the value has changed. We will receive one of these events

    // any time the user presses a modifier key, which can result in errant

    // mouse motion when using a Citrix X1 mouse.

    if (x != lastMouseX || y != lastMouseY) {

        if (lastMouseX != 0 || lastMouseY != 0) {

            LiSendMousePositionEvent(x - videoOrigin.x, y - videoOrigin.y,

                                     videoSize.width, videoSize.height);

        }

        

        lastMouseX = x;

        lastMouseY = y;

    }

}


- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction

                       regionForRequest:(UIPointerRegionRequest *)request

                          defaultRegion:(UIPointerRegion *)defaultRegion API_AVAILABLE(ios(13.4)) {

    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect

    CGSize videoSize;

    CGPoint videoOrigin;

    if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {

        videoSize = CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);

    } else {

        videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);

    }

    videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,

                              self.bounds.size.height / 2 - videoSize.height / 2);

    

    // Move the cursor on the host if no buttons are pressed.

    // Motion with buttons pressed in handled in touchesMoved:

    if (lastMouseButtonMask == 0) {

        [self updateCursorLocation:request.location];

    }

    

    // The pointer interaction should cover the video region only

    return [UIPointerRegion regionWithRect:CGRectMake(videoOrigin.x, videoOrigin.y, videoSize.width, videoSize.height) identifier:nil];

}


- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region  API_AVAILABLE(ios(13.4)) {

    // Always hide the mouse cursor over our stream view

    return [UIPointerStyle hiddenPointerStyle];

}


- (void)mouseWheelMoved:(UIPanGestureRecognizer *)gesture {

    switch (gesture.state) {

        case UIGestureRecognizerStateBegan:

        case UIGestureRecognizerStateChanged:

        case UIGestureRecognizerStateEnded:

            break;

            

        default:

            // Ignore recognition failure and other states

            return;

    }

    

    CGPoint velocity = [gesture velocityInView:self];

    if ((short)velocity.y != 0) {

        LiSendHighResScrollEvent((short)velocity.y);

    }

}


#endif


- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {

    // Если это наш джойстик — разрешаем!

    if ([gestureRecognizer.view isEqual:self.superview]) {

        return YES;

    }

    // Для всего остального (системные меню iOS 13+) оставляем NO

    return NO;

}


- (BOOL)textFieldShouldReturn:(UITextField *)textField {

    // This method is called when the "Return" key is pressed.

    LiSendKeyboardEvent(0x0d, KEY_ACTION_DOWN, 0);

    usleep(50 * 1000);

    LiSendKeyboardEvent(0x0d, KEY_ACTION_UP, 0);

    return NO;

}


- (void)onKeyboardPressed:(UITextField *)textField {

    NSString* inputText = textField.text;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // If the text became empty, we know the user pressed the backspace key.

        if ([inputText isEqual:@""]) {

            LiSendKeyboardEvent(0x08, KEY_ACTION_DOWN, 0);

            usleep(50 * 1000);

            LiSendKeyboardEvent(0x08, KEY_ACTION_UP, 0);

        } else {

            // Character 0 will be our known sentinel value

            for (int i = 1; i < [inputText length]; i++) {

                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];

                if (event.keycode == 0) {

                    // If we don't know the code, don't send anything.

                    Log(LOG_W, @"Unknown key code: [%c]", [inputText characterAtIndex:i]);

                    continue;

                }

                [self sendLowLevelEvent:event];

            }

        }

    });

    

    // Reset text field back to known state

    textField.text = @"0";

    

    // Move the insertion point back to the end of the text box

    UITextRange *textRange = [textField textRangeFromPosition:textField.endOfDocument toPosition:textField.endOfDocument];

    [textField setSelectedTextRange:textRange];

}


- (void)specialCharPressed:(UIKeyCommand *)cmd {

    struct KeyEvent event = [KeyboardSupport translateKeyEvent:0x20 withModifierFlags:[cmd modifierFlags]];

    event.keycode = [[dictCodes valueForKey:[cmd input]] intValue];

    [self sendLowLevelEvent:event];

}


- (void)keyPressed:(UIKeyCommand *)cmd {

    struct KeyEvent event = [KeyboardSupport translateKeyEvent:[[cmd input] characterAtIndex:0] withModifierFlags:[cmd modifierFlags]];

    [self sendLowLevelEvent:event];

}


- (void)sendLowLevelEvent:(struct KeyEvent)event {

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // When we want to send a modified key (like uppercase letters) we need to send the

        // modifier ("shift") seperately from the key itself.

        if (event.modifier != 0) {

            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_DOWN, event.modifier);

        }

        LiSendKeyboardEvent(event.keycode, KEY_ACTION_DOWN, event.modifier);

        usleep(50 * 1000);

        LiSendKeyboardEvent(event.keycode, KEY_ACTION_UP, event.modifier);

        if (event.modifier != 0) {

            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_UP, event.modifier);

        }

    });

}


- (BOOL)canBecomeFirstResponder {

    return NO;

}


- (NSArray<UIKeyCommand *> *)keyCommands

{

    NSString *charset = @"qwertyuiopasdfghjklzxcvbnm1234567890\t§[]\\'\"/.,`<>-´ç+`¡'º;ñ= ";

    

    NSMutableArray<UIKeyCommand *> * commands = [NSMutableArray<UIKeyCommand *> array];

    dictCodes = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt: 0x0d], @"\r", [NSNumber numberWithInt: 0x08], @"\b", [NSNumber numberWithInt: 0x1b], UIKeyInputEscape, [NSNumber numberWithInt: 0x28], UIKeyInputDownArrow, [NSNumber numberWithInt: 0x26], UIKeyInputUpArrow, [NSNumber numberWithInt: 0x25], UIKeyInputLeftArrow, [NSNumber numberWithInt: 0x27], UIKeyInputRightArrow, nil];

    

    [charset enumerateSubstringsInRange:NSMakeRange(0, charset.length)

                                options:NSStringEnumerationByComposedCharacterSequences

                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {

        [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:0 action:@selector(keyPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierShift action:@selector(keyPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierControl action:@selector(keyPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierAlternate action:@selector(keyPressed:)]];

    }];

    

    for (NSString *c in [dictCodes keyEnumerator]) {

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:0

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierShift

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierShift | UIKeyModifierAlternate

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierShift | UIKeyModifierControl

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierControl

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate

                                                       action:@selector(specialCharPressed:)]];

        [commands addObject:[UIKeyCommand keyCommandWithInput:c

                                                modifierFlags:UIKeyModifierAlternate

                                                       action:@selector(specialCharPressed:)]];

    }

    

    return commands;

}


- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {

    NSLog(@"Citrix X1 mouse state change: %@ -> %s",

          identifier, isConnected ? "connected" : "disconnected");

}


- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {

    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;

    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;

    

    short shortX = (short)accumulatedMouseDeltaX;

    short shortY = (short)accumulatedMouseDeltaY;

    

    if (shortX == 0 && shortY == 0) {

        return;

    }

    

    LiSendMouseMoveEvent(shortX, shortY);

    

    accumulatedMouseDeltaX -= shortX;

    accumulatedMouseDeltaY -= shortY;

}


- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {

    switch (button) {

        case X1MouseButtonLeft:

            return BUTTON_LEFT;

        case X1MouseButtonRight:

            return BUTTON_RIGHT;

        case X1MouseButtonMiddle:

            return BUTTON_MIDDLE;

        default:

            return -1;

    }

}


- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {

    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);

}


- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {

    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);

}


- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {

    LiSendScrollEvent(deltaZ);

}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    // Обновляем displayLayer при изменении размера вью
    for (CALayer *sublayer in self.layer.sublayers) {
        if ([sublayer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            sublayer.frame = self.bounds;
        }
    }
}

#pragma mark - Touch ID Tracking

- (uint32_t)pointerIdForTouch:(UITouch *)touch create:(BOOL)create {
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)touch];
    NSNumber *existing = [_activeTouches objectForKey:key];
    if (existing) return [existing unsignedIntValue];
    if (!create) return UINT32_MAX;
    
    uint32_t newId = _nextPointerId++;
    [_activeTouches setObject:@(newId) forKey:key];
    return newId;
}

- (void)releasePointerIdForTouch:(UITouch *)touch {
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)touch];
    [_activeTouches removeObjectForKey:key];
}

- (void)sendTouchEvent:(uint8_t)eventType forTouch:(UITouch *)touch {
    CGPoint loc = [touch locationInView:self];
    float nx = loc.x / self.bounds.size.width;
    float ny = loc.y / self.bounds.size.height;
    
    // Ограничиваем координаты
    nx = fmax(0.0f, fmin(1.0f, nx));
    ny = fmax(0.0f, fmin(1.0f, ny));
    
    BOOL create = (eventType == LI_TOUCH_EVENT_DOWN);
    uint32_t pid = [self pointerIdForTouch:touch create:create];
    
    if (pid == UINT32_MAX) return;
    
    LiSendTouchEvent(eventType, pid, nx, ny,
                     1.0f,    // pressure
                     0.04f,   // contactAreaMajor (4% экрана)
                     0.04f,   // contactAreaMinor
                     0);      // rotation
    
    if (eventType == LI_TOUCH_EVENT_UP || eventType == LI_TOUCH_EVENT_CANCEL) {
        [self releasePointerIdForTouch:touch];
    }
}

- (void)toggleTabletMode {
    _tabletMode = !_tabletMode;
    NSLog(@"[Touch] Tablet mode: %@", _tabletMode ? @"ON" : @"OFF");
}


@end

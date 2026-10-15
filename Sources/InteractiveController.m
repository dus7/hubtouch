//
//  InteractiveController.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "InteractiveController.h"
#import "CoreSimulator.h"
#import "DeviceHub.h"
#import "FingerOverlayView.h"
#import "Fingers.h"
#import "SimulatorRouter.h"
#import "SimulatorShortcuts.h"
#import "Support.h"
#import "TouchSender.h"

/// Accessibility messaging timeout, short so a busy Device Hub cannot stall the event taps.
static const float AccessibilityTimeoutSeconds = 0.1;

/// Minimum time between accessibility lookups while hovering over Device Hub outside a simulator screen.
static const NSTimeInterval HoverLookupIntervalSeconds = 0.05;

@implementation InteractiveController {
    SimulatorRouter *_router;
    /// Swallows mouse and key events that belong to gestures and shortcuts.
    CFMachPortRef _gestureTap;
    /// Observes pointer moves and modifier changes for the preview; listen-only, so it never holds up event delivery.
    CFMachPortRef _hoverTap;
    NSTimer *_permissionPollTimer;
    NSPanel *_overlayPanel;
    FingerOverlayView *_overlayView;

    /// Gesture in progress: the sender and screen rect chosen at touch down; nil sender means no gesture.
    TouchSender *_gestureSender;
    CGRect _gestureScreenRect;
    FingerPair _lastFingers;
    /// Second finger's offset from the first while Shift locks the pair together for a two-finger drag.
    CGPoint _lockedPairOffset;
    BOOL _pairLocked;
    /// After a cancelled gesture, the rest of its physical drag is swallowed so Device Hub never sees half a drag.
    BOOL _discardingCancelledDrag;

    /// Simulator screen found while hovering with Option held, reused while the cursor stays inside it.
    CGRect _hoverScreenRect;
    NSTimeInterval _lastHoverLookupTime;
    /// Normalized point the fingers mirror around; Option+Shift hover moves it, as in Simulator.app.
    CGPoint _mirrorCenter;
    CGPoint _mirrorCenterGrabOffset;
    BOOL _movingMirrorCenter;
}

- (instancetype)initWithRouter:(SimulatorRouter *)router {
    if ((self = [super init])) {
        _router = router;
        _hoverScreenRect = CGRectNull;
        _mirrorCenter = CGPointMake(0.5, 0.5);
    }
    return self;
}

- (BOOL)listening {
    return _gestureTap != NULL;
}

static CGEventRef HandleGestureTapEvent(__unused CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    return [(__bridge InteractiveController *)context handleGestureEvent:event type:type];
}

static CGEventRef HandleHoverTapEvent(__unused CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    [(__bridge InteractiveController *)context handleHoverEvent:event type:type];
    return event;
}

- (void)start {
    [self makeOverlay];
    NSDictionary *promptOptions = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES };
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)promptOptions)) {
        Log(@"waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)");
    }
    [self updateListeningForPermission];
    // An active tap left running after its permission changes can stall every click and keystroke on the system,
    // so permission changes stop or start the taps right away, with a periodic check as a backstop.
    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(accessibilityPermissionMayHaveChanged)
                                                          name:@"com.apple.accessibility.api"
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    _permissionPollTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                            target:self
                                                          selector:@selector(updateListeningForPermission)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)accessibilityPermissionMayHaveChanged {
    // The trust state settles shortly after the notification is posted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self updateListeningForPermission];
    });
}

- (void)updateListeningForPermission {
    BOOL trusted = AXIsProcessTrusted();
    if (trusted && !self.listening) {
        [self startListening];
    } else if (!trusted && self.listening) {
        Log(@"Accessibility permission removed; stopping event taps");
        [self stopListening];
    }
}

- (void)stopListening {
    [self cancelTouch];
    [self hideFingers];
    InvalidateEventTap(&_gestureTap);
    InvalidateEventTap(&_hoverTap);
    if (self.listeningDidChange) {
        self.listeningDidChange();
    }
}

static NSString *EventTapDisabledReason(CGEventType type) {
    return type == kCGEventTapDisabledByTimeout ? @"timeout" : @"user input";
}

/// Disables and removes an event tap; invalidating its port also removes its run loop source.
static void InvalidateEventTap(CFMachPortRef *tap) {
    if (!*tap) {
        return;
    }
    CGEventTapEnable(*tap, false);
    CFMachPortInvalidate(*tap);
    CFRelease(*tap);
    *tap = NULL;
}

- (void)startListening {
    // Set on the system-wide element, the timeout applies to every accessibility element this process queries.
    id systemWide = CFBridgingRelease(AXUIElementCreateSystemWide());
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)systemWide, AccessibilityTimeoutSeconds);

    // Keyboard events in an event tap may also need Input Monitoring; this asks once and is otherwise a no-op.
    if (!CGPreflightListenEventAccess()) {
        Log(@"Input Monitoring not granted; keyboard shortcuts may not reach HubTouch");
        CGRequestListenEventAccess();
    }

    _gestureTap = [self addEventTapWithMask:CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                                            CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventKeyDown)
                                    options:kCGEventTapOptionDefault
                                   callback:HandleGestureTapEvent];
    _hoverTap = [self addEventTapWithMask:CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventFlagsChanged)
                                  options:kCGEventTapOptionListenOnly
                                 callback:HandleHoverTapEvent];
    if (!_gestureTap || !_hoverTap) {
        Log(@"cannot create event taps");
        InvalidateEventTap(&_gestureTap);
        InvalidateEventTap(&_hoverTap);
        return;
    }
    if (self.listeningDidChange) {
        self.listeningDidChange();
    }
}

- (CFMachPortRef)addEventTapWithMask:(CGEventMask)mask options:(CGEventTapOptions)options callback:(CGEventTapCallBack)callback {
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, options, mask, callback, (__bridge void *)self);
    if (tap) {
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
    }
    return tap;
}

- (void)makeOverlay {
    _overlayPanel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES];
    _overlayPanel.opaque = NO;
    _overlayPanel.backgroundColor = NSColor.clearColor;
    _overlayPanel.ignoresMouseEvents = YES;
    _overlayPanel.hasShadow = NO;
    _overlayPanel.level = NSScreenSaverWindowLevel;
    _overlayPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary;
    _overlayView = [FingerOverlayView new];
    _overlayPanel.contentView = _overlayView;
}

#pragma mark Gestures

- (CGEventRef)handleGestureEvent:(CGEventRef)event type:(CGEventType)type {
    CGPoint location = CGEventGetLocation(event);
    switch (type) {
        case kCGEventTapDisabledByTimeout:
        case kCGEventTapDisabledByUserInput:
            // The gesture's remaining events were missed, so its up event will never be seen.
            _discardingCancelledDrag = _gestureSender != nil;
            [self cancelTouch];
            [self hideFingers];
            // Only a timeout is ours to undo; a tap the system disabled on purpose stays off.
            if (type == kCGEventTapDisabledByTimeout) {
                CGEventTapEnable(_gestureTap, true);
            }
            Log([NSString stringWithFormat:@"gesture tap disabled (%@); %@", EventTapDisabledReason(type),
                                           type == kCGEventTapDisabledByTimeout ? @"re-enabled" : @"left off"]);
            return event;
        case kCGEventKeyDown:
            return [self handleKeyDown:event];
        case kCGEventLeftMouseDown:
            _discardingCancelledDrag = NO;
            return [self beginTouchAtLocation:location flags:CGEventGetFlags(event)] ? NULL : event;
        case kCGEventLeftMouseDragged:
            if (_discardingCancelledDrag) {
                return NULL;
            }
            if (!_gestureSender) {
                return event;
            }
            [self touchAtLocation:location eventType:NSEventTypeLeftMouseDragged];
            return NULL;
        case kCGEventLeftMouseUp:
            if (_discardingCancelledDrag) {
                _discardingCancelledDrag = NO;
                return NULL;
            }
            if (!_gestureSender) {
                return event;
            }
            [self touchAtLocation:location eventType:NSEventTypeLeftMouseUp];
            [self endTouch];
            return NULL;
        default:
            return event;
    }
}

/// Starts a gesture when Option is held over a simulator screen whose simulator is connected.
- (BOOL)beginTouchAtLocation:(CGPoint)location flags:(CGEventFlags)flags {
    CGWindowID windowID = 0;
    pid_t ownerProcessID = 0;
    if (!(flags & kCGEventFlagMaskAlternate) || !TopmostWindowAtPoint(location, &windowID, &ownerProcessID) ||
        !IsDeviceHubProcess(ownerProcessID)) {
        return NO;
    }
    id window = nil;
    CGRect screenRect = DeviceHubScreenAtPoint(ownerProcessID, location, &window);
    if (!CGRectContainsPoint(screenRect, location) || !window) {
        return NO;
    }
    NSString *udid = [_router deviceUDIDForWindow:window windowID:windowID];
    TouchSender *sender = udid ? [_router readySenderForUDID:udid] : nil;
    if (!sender) {
        Log(udid ? @"simulator still connecting, passing the click through" : @"cannot tell which simulator this window shows");
        return NO;
    }

    _gestureSender = sender;
    _gestureScreenRect = screenRect;
    _pairLocked = (flags & kCGEventFlagMaskShift) != 0;
    if (_pairLocked) {
        // The pair starts mirrored and then moves together for the rest of the gesture.
        FingerPair mirrored = [self mirroredFingersAtLocation:location screenRect:screenRect];
        _lockedPairOffset = CGPointMake(mirrored.second.x - mirrored.first.x, mirrored.second.y - mirrored.first.y);
    }
    [self touchAtLocation:location eventType:NSEventTypeLeftMouseDown];
    return YES;
}

- (void)touchAtLocation:(CGPoint)location eventType:(NSEventType)eventType {
    FingerPair fingers = [self fingersAtLocation:location screenRect:_gestureScreenRect];
    [_gestureSender sendFingers:fingers eventType:eventType];
    _lastFingers = fingers;
    // The hover preview shows the fingers again on the next Option move, so nothing lingers after a gesture.
    if (eventType == NSEventTypeLeftMouseUp) {
        [self hideFingers];
    } else {
        [self showFingers:fingers screenRect:_gestureScreenRect pressed:YES];
    }
}

- (void)endTouch {
    _gestureSender = nil;
    _pairLocked = NO;
}

- (void)cancelTouch {
    if (!_gestureSender) {
        return;
    }
    [_gestureSender sendFingers:_lastFingers eventType:NSEventTypeLeftMouseUp];
    [self endTouch];
    [self hideFingers];
}

- (FingerPair)mirroredFingersAtLocation:(CGPoint)location screenRect:(CGRect)screenRect {
    CGPoint first = NormalizedPoint(location, screenRect);
    CGPoint second = CGPointMake(2 * _mirrorCenter.x - first.x, 2 * _mirrorCenter.y - first.y);
    return (FingerPair){ .first = first, .second = ClampToUnitSquare(second) };
}

- (FingerPair)fingersAtLocation:(CGPoint)location screenRect:(CGRect)screenRect {
    if (!_pairLocked) {
        return [self mirroredFingersAtLocation:location screenRect:screenRect];
    }
    CGPoint first = NormalizedPoint(location, screenRect);
    CGPoint second = CGPointMake(first.x + _lockedPairOffset.x, first.y + _lockedPairOffset.y);
    return (FingerPair){ .first = first, .second = ClampToUnitSquare(second) };
}

#pragma mark Hover preview

- (void)handleHoverEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // A listen-only tap cannot hold up input, and the preview depends on it to hide the fingers.
        Log([NSString stringWithFormat:@"hover tap disabled (%@); re-enabling", EventTapDisabledReason(type)]);
        [self hideFingers];
        CGEventTapEnable(_hoverTap, true);
        return;
    }
    if (_gestureSender) {
        return;
    }
    CGEventFlags flags = CGEventGetFlags(event);
    if (!(flags & kCGEventFlagMaskAlternate)) {
        _hoverScreenRect = CGRectNull;
        _mirrorCenter = CGPointMake(0.5, 0.5);
        _movingMirrorCenter = NO;
        [self hideFingers];
        return;
    }

    CGPoint location = CGEventGetLocation(event);
    CGRect previousScreenRect = _hoverScreenRect;
    CGRect screenRect = [self hoverScreenRectAtLocation:location];
    if (CGRectIsNull(screenRect)) {
        _movingMirrorCenter = NO;
        [self hideFingers];
        return;
    }
    if (!CGRectEqualToRect(screenRect, previousScreenRect)) {
        // The center is relative to one screen; another simulator starts from its own center.
        _mirrorCenter = CGPointMake(0.5, 0.5);
        _movingMirrorCenter = NO;
    }
    [self moveMirrorCenterWithCursor:location screenRect:screenRect shiftHeld:(flags & kCGEventFlagMaskShift) != 0];
    [self showFingers:[self mirroredFingersAtLocation:location screenRect:screenRect] screenRect:screenRect pressed:NO];
}

/// Simulator screen under the cursor for the preview, skipping lookups while the answer cannot have changed.
- (CGRect)hoverScreenRectAtLocation:(CGPoint)location {
    if (CGRectContainsPoint(_hoverScreenRect, location)) {
        return _hoverScreenRect;
    }
    _hoverScreenRect = CGRectNull;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - _lastHoverLookupTime < HoverLookupIntervalSeconds) {
        return CGRectNull;
    }
    _lastHoverLookupTime = now;

    CGWindowID windowID = 0;
    pid_t ownerProcessID = 0;
    if (!TopmostWindowAtPoint(location, &windowID, &ownerProcessID) || !IsDeviceHubProcess(ownerProcessID)) {
        return CGRectNull;
    }
    CGRect screenRect = DeviceHubScreenAtPoint(ownerProcessID, location, NULL);
    if (CGRectContainsPoint(screenRect, location)) {
        _hoverScreenRect = screenRect;
    }
    return _hoverScreenRect;
}

/// While Shift is held during an Option hover, the mirror center follows the cursor so both fingers move together.
- (void)moveMirrorCenterWithCursor:(CGPoint)location screenRect:(CGRect)screenRect shiftHeld:(BOOL)shiftHeld {
    if (!shiftHeld) {
        _movingMirrorCenter = NO;
        return;
    }
    CGPoint cursor = NormalizedPoint(location, screenRect);
    if (!_movingMirrorCenter) {
        _movingMirrorCenter = YES;
        _mirrorCenterGrabOffset = CGPointMake(cursor.x - _mirrorCenter.x, cursor.y - _mirrorCenter.y);
    }
    _mirrorCenter = ClampToUnitSquare(CGPointMake(cursor.x - _mirrorCenterGrabOffset.x, cursor.y - _mirrorCenterGrabOffset.y));
}

#pragma mark Overlay

- (void)showFingers:(FingerPair)fingers screenRect:(CGRect)screenRect pressed:(BOOL)pressed {
    // Window frames use Cocoa coordinates, which grow upward from the bottom of the primary display.
    CGFloat primaryScreenHeight = NSScreen.screens.firstObject.frame.size.height;
    NSRect screenFrame = NSMakeRect(screenRect.origin.x, primaryScreenHeight - CGRectGetMaxY(screenRect), screenRect.size.width,
                                    screenRect.size.height);
    NSRect panelFrame = NSInsetRect(screenFrame, -FingerDotDiameter / 2, -FingerDotDiameter / 2);
    if (!NSEqualRects(_overlayPanel.frame, panelFrame)) {
        [_overlayPanel setFrame:panelFrame display:NO];
    }
    _overlayView.fingers = fingers;
    _overlayView.pressed = pressed;
    _overlayView.needsDisplay = YES;
    if (!_overlayPanel.visible) {
        [_overlayPanel orderFrontRegardless];
    }
}

- (void)hideFingers {
    if (_overlayPanel.visible) {
        [_overlayPanel orderOut:nil];
    }
}

#pragma mark Shortcuts

/// Swallows Command+S and Command+Shift+A while Device Hub is frontmost; the slow lookups run after the tap returns.
- (CGEventRef)handleKeyDown:(CGEventRef)event {
    SimulatorShortcut shortcut;
    if (!ShortcutForKeyEvent(event, &shortcut)) {
        return event;
    }
    // Compared by bundle identifier: the frontmost application's process identifier is not always populated.
    if (![NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:DeviceHubBundleIdentifier]) {
        return event;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performShortcut:shortcut];
    });
    return NULL;
}

- (void)performShortcut:(SimulatorShortcut)shortcut {
    id window = DeviceHubFocusedWindow();
    if (!window) {
        Log(@"shortcut: no focused Device Hub window");
        NSBeep();
        return;
    }
    // The focused window's ID is not available through public accessibility API, so this lookup is not cached.
    NSString *udid = [_router deviceUDIDForWindow:window windowID:0];
    if (!udid) {
        Log(@"shortcut: cannot tell which simulator the focused window shows");
        NSBeep();
        return;
    }
    Log([NSString stringWithFormat:@"shortcut %@ for %@", shortcut == SimulatorShortcutScreenshot ? @"screenshot" : @"appearance", udid]);
    NSString *deviceName = [DeviceWithUDID(udid) valueForKey:@"name"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL succeeded = shortcut == SimulatorShortcutScreenshot ? SaveScreenshotToDesktop(udid, deviceName) : ToggleAppearance(udid);
        if (!succeeded) {
            BeepOnMainQueue();
        }
    });
}

@end

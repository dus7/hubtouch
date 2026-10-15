//
//  hubtouch.m
//  Restores two-finger touch input and Simulator.app shortcuts for iOS Simulators shown in Xcode 27's Device Hub,
//  through CoreSimulator's private `dtuhidd` HID service.
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <xpc/xpc.h>

#pragma mark - Process helpers

static void Log(NSString *message) {
    fprintf(stderr, "hubtouch: %s\n", message.UTF8String);
}

static void Fail(NSString *message) {
    Log(message);
    exit(1);
}

static void BeepOnMainQueue(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSBeep();
    });
}

/// Runs a command-line tool and returns its trimmed standard output, or nil if it cannot run or exits with an error.
static NSString *RunTool(NSString *executablePath, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        return nil;
    }
    // Read before waiting, so a full pipe cannot keep the tool from exiting.
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        Log([NSString stringWithFormat:@"%@ %@ failed", executablePath.lastPathComponent, [arguments componentsJoinedByString:@" "]]);
        return nil;
    }
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *RunSimctl(NSArray<NSString *> *arguments) {
    return RunTool(@"/usr/bin/xcrun", [@[ @"simctl" ] arrayByAddingObjectsFromArray:arguments]);
}

static NSString *ActiveDeveloperDirectory(void) {
    NSString *fromEnvironment = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    return fromEnvironment.length > 0 ? fromEnvironment : RunTool(@"/usr/bin/xcode-select", @[ @"-p" ]);
}

#pragma mark - CoreSimulator

/// SimDeviceState value for a booted simulator.
static const NSUInteger SimDeviceStateBooted = 3;

static void LoadCoreSimulator(void) {
    NSString *path = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        Fail([NSString stringWithFormat:@"cannot load %@: %s", path, dlerror()]);
    }
}

/// CoreSimulator's default device set for the active developer directory; it keeps device states current itself.
static id DefaultDeviceSet(void) {
    static id deviceSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSError *error = nil;
        id serviceContext = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
            NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
            ActiveDeveloperDirectory(), &error);
        deviceSet = ((id(*)(id, SEL, NSError **))objc_msgSend)(serviceContext, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
        if (!deviceSet) {
            Log([NSString stringWithFormat:@"no simulator device set: %@", error]);
        }
    });
    return deviceSet;
}

static NSString *DeviceUDID(id device) {
    return [[device valueForKey:@"UDID"] UUIDString];
}

static BOOL IsBooted(id device) {
    return [[device valueForKey:@"state"] unsignedIntegerValue] == SimDeviceStateBooted;
}

static id DeviceWithUDID(NSString *udid) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    return uuid ? [DefaultDeviceSet() valueForKey:@"devicesByUDID"][uuid] : nil;
}

static NSArray *BootedDevices(void) {
    NSArray *devices = [[DefaultDeviceSet() valueForKey:@"devicesByUDID"] allValues];
    return [devices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id device, __unused NSDictionary *bindings) {
        return IsBooted(device);
    }]];
}

static NSString *DeviceRuntimeName(id device) {
    @try {
        return [device valueForKeyPath:@"runtime.name"];
    } @catch (__unused NSException *exception) {
        // The runtime only refines matching and labels; the device name alone still works.
        return nil;
    }
}

static NSString *DeviceTitle(id device) {
    NSString *name = [device valueForKey:@"name"];
    NSString *runtimeName = DeviceRuntimeName(device);
    return runtimeName ? [NSString stringWithFormat:@"%@ (%@)", name, runtimeName] : name;
}

#pragma mark - Fingers

/// Pair of finger positions in normalized 0...1 screen space, origin at the top left.
typedef struct {
    CGPoint first;
    CGPoint second;
} FingerPair;

/// Gesture expressed as finger positions over progress 0...1.
typedef FingerPair (^GesturePath)(double progress);

static CGPoint ClampToUnitSquare(CGPoint point) {
    return CGPointMake(MIN(MAX(point.x, 0), 1), MIN(MAX(point.y, 0), 1));
}

/// Location in global display coordinates expressed in the normalized space of the screen rect.
static CGPoint NormalizedPoint(CGPoint location, CGRect screenRect) {
    return ClampToUnitSquare(CGPointMake((location.x - screenRect.origin.x) / screenRect.size.width,
                                         (location.y - screenRect.origin.y) / screenRect.size.height));
}

static FingerPair MirroredFingers(CGPoint center, double radius, double angleRadians) {
    CGFloat offsetX = radius * cos(angleRadians);
    CGFloat offsetY = radius * sin(angleRadians);
    return (FingerPair){
        .first = CGPointMake(center.x - offsetX, center.y - offsetY),
        .second = CGPointMake(center.x + offsetX, center.y + offsetY),
    };
}

#pragma mark - DTUHID transport

/// Guest HID service that receives digitizer events from the host.
static NSString *const DigitizerServiceName = @"com.apple.coredevice.feature.remote.hid.digitizer";

/// Deadline for `dtuhidd` to answer a barrier; the first one may have to launch the daemon.
static const int64_t DigitizerBarrierTimeoutNanoseconds = 4 * NSEC_PER_SEC;

/// Time for `dtuhidd` to open the device after it first answers.
static const useconds_t DigitizerActivationDelayMicroseconds = 200000;

/// Pace of scripted gestures, about one display frame per step.
static const useconds_t GestureStepIntervalMicroseconds = 16000;

static const int DefaultStepCount = 20;

typedef xpc_object_t __attribute__((ns_returns_retained)) (*EndpointFromMachPortFunction)(mach_port_t port, uint64_t, uint64_t);
typedef xpc_connection_t __attribute__((ns_returns_retained)) (*ConnectionFromEndpointFunction)(xpc_object_t endpoint);
typedef void (*EnableSimulatorToHostFunction)(xpc_connection_t connection);

static xpc_object_t DTUHIDMessage(const char *messageType, BOOL isBarrier, xpc_object_t payload) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", messageType);
    xpc_dictionary_set_bool(message, "isBarrier", isBarrier);
    xpc_dictionary_set_string(message, "featureIdentifier", DigitizerServiceName.UTF8String);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

static xpc_object_t DigitizerPoint(CGPoint point) {
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(dictionary, "x", point.x);
    xpc_dictionary_set_double(dictionary, "y", point.y);
    return dictionary;
}

/// `IndigoDigitizerEvent` contact phase: start, position or end.
static uint64_t DigitizerEventType(NSEventType eventType) {
    switch (eventType) {
        case NSEventTypeLeftMouseDown:
            return 0;
        case NSEventTypeLeftMouseUp:
            return 2;
        default:
            return 1;
    }
}

/// Sends a barrier and waits for `dtuhidd` to answer it, which also means every earlier message was handled.
static BOOL WaitForDigitizerBarrier(xpc_connection_t connection, dispatch_queue_t queue) {
    // A keyboard event with usage 0 means "no event", so the barrier reaches the daemon without a keypress.
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", 0);
    xpc_dictionary_set_uint64(payload, "state", 2);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL delivered = NO;
    xpc_connection_send_message_with_reply(connection, DTUHIDMessage("IndigoKeyboardButtonEvent", YES, payload), queue,
                                           ^(xpc_object_t reply) {
                                               delivered = xpc_get_type(reply) != XPC_TYPE_ERROR;
                                               dispatch_semaphore_signal(answered);
                                           });
    BOOL timedOut = dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, DigitizerBarrierTimeoutNanoseconds)) != 0;
    return !timedOut && delivered;
}

/// Connects to the simulator's `dtuhidd` digitizer service, or returns nil when no daemon answers.
/// The service lookup succeeds even when `dtuhidd` cannot run, so only an answered barrier proves the path works.
static xpc_connection_t ConnectDigitizerService(id device, dispatch_queue_t queue, void (^connectionDidFail)(void)) {
    EndpointFromMachPortFunction endpointFromMachPort = dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    ConnectionFromEndpointFunction connectionFromEndpoint = dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
    EnableSimulatorToHostFunction enableSimulatorToHost = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromMachPort || !connectionFromEndpoint || !enableSimulatorToHost) {
        Log(@"private XPC symbols for simulator services not found");
        return nil;
    }

    NSError *error = nil;
    mach_port_t port = ((mach_port_t(*)(id, SEL, id, NSError **))objc_msgSend)(
        device, NSSelectorFromString(@"lookup:error:"), DigitizerServiceName, &error);
    if (port == MACH_PORT_NULL) {
        Log([NSString stringWithFormat:@"digitizer service lookup failed: %@", error]);
        return nil;
    }
    xpc_object_t endpoint = endpointFromMachPort(port, 0, 0);
    xpc_connection_t connection = endpoint ? connectionFromEndpoint(endpoint) : nil;
    if (!connection) {
        Log(@"cannot create a connection to the digitizer service");
        return nil;
    }
    // Without this the service sees the peer but never a payload.
    enableSimulatorToHost(connection);
    xpc_connection_set_target_queue(connection, queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            connectionDidFail();
        }
    });
    xpc_connection_resume(connection);

    if (!WaitForDigitizerBarrier(connection, queue)) {
        Log(@"dtuhidd did not answer");
        xpc_connection_cancel(connection);
        return nil;
    }
    usleep(DigitizerActivationDelayMicroseconds);
    return connection;
}

/// Two-finger touch connection to one simulator's `dtuhidd`.
@interface TouchSender : NSObject
/// Connects to the device, blocking for up to a few seconds while `dtuhidd` starts. Returns nil if it does not answer.
- (nullable instancetype)initWithDevice:(id)device;
/// NO once the connection fails, for example because the simulator shut down.
@property (atomic, readonly) BOOL valid;
- (void)sendFingers:(FingerPair)fingers eventType:(NSEventType)eventType;
/// Plays a gesture and returns once the simulator has received it.
- (void)performPath:(GesturePath)path steps:(int)steps;
@end

@implementation TouchSender {
    xpc_connection_t _connection;
    dispatch_queue_t _queue;
}

- (instancetype)initWithDevice:(id)device {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("hubtouch.hid", DISPATCH_QUEUE_SERIAL);
        __weak TouchSender *weakSelf = self;
        _connection = ConnectDigitizerService(device, _queue, ^{
            [weakSelf invalidate];
        });
        if (!_connection) {
            return nil;
        }
        _valid = YES;
    }
    return self;
}

- (void)dealloc {
    if (_connection) {
        xpc_connection_cancel(_connection);
    }
}

- (void)invalidate {
    _valid = NO;
}

- (void)sendFingers:(FingerPair)fingers eventType:(NSEventType)eventType {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", DigitizerPoint(fingers.first));
    xpc_dictionary_set_value(payload, "pointTwo", DigitizerPoint(fingers.second));
    xpc_dictionary_set_uint64(payload, "eventType", DigitizerEventType(eventType));
    xpc_dictionary_set_uint64(payload, "edge", 0);
    xpc_dictionary_set_uint64(payload, "target", 0);
    xpc_connection_send_message(_connection, DTUHIDMessage("IndigoDigitizerEvent", NO, payload));
}

- (void)performPath:(GesturePath)path steps:(int)steps {
    [self sendFingers:path(0) eventType:NSEventTypeLeftMouseDown];
    for (int step = 1; step <= steps; step++) {
        usleep(GestureStepIntervalMicroseconds);
        [self sendFingers:path((double)step / steps) eventType:NSEventTypeLeftMouseDragged];
    }
    usleep(GestureStepIntervalMicroseconds);
    [self sendFingers:path(1) eventType:NSEventTypeLeftMouseUp];
    if (!WaitForDigitizerBarrier(_connection, _queue)) {
        Log(@"the simulator did not confirm the gesture");
    }
}

@end

#pragma mark - Device Hub accessibility

static NSString *const DeviceHubBundleIdentifier = @"com.apple.dt.Devices";

/// Accessibility subrole Device Hub gives the view showing a simulator's screen.
static NSString *const DeviceScreenSubrole = @"iOSContentGroup";

/// Prefix of the accessibility identifier on Device Hub sidebar rows; the device UDID follows it.
static NSString *const DeviceRowIdentifierPrefix = @"TableRow.Device.";

/// Accessibility messaging timeout, short so a busy Device Hub cannot stall the event taps.
static const float AccessibilityTimeoutSeconds = 0.1;

/// Depth limits for searching a Device Hub window; the sidebar sits near the top of its tree.
static const int SidebarSearchDepth = 10;
static const int RowIdentifierSearchDepth = 4;

static BOOL IsDeviceHubProcess(pid_t processID) {
    static pid_t deviceHubProcessID;
    if (processID == deviceHubProcessID) {
        return YES;
    }
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:processID];
    if (![application.bundleIdentifier isEqualToString:DeviceHubBundleIdentifier]) {
        return NO;
    }
    deviceHubProcessID = processID;
    return YES;
}

/// Topmost normal window under a point in global display coordinates.
static BOOL TopmostWindowAtPoint(CGPoint point, CGWindowID *windowID, pid_t *ownerProcessID) {
    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        CGRect bounds;
        if ([window[(__bridge NSString *)kCGWindowLayer] integerValue] != 0 ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds) ||
            !CGRectContainsPoint(bounds, point)) {
            continue;
        }
        *windowID = [window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
        *ownerProcessID = [window[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        return YES;
    }
    return NO;
}

static id AccessibilityAttribute(id element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (!element || AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element, attribute, &value) != kAXErrorSuccess) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSString *AccessibilityString(id element, CFStringRef attribute) {
    id value = AccessibilityAttribute(element, attribute);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static CGRect AccessibilityFrame(id element) {
    id position = AccessibilityAttribute(element, kAXPositionAttribute);
    id size = AccessibilityAttribute(element, kAXSizeAttribute);
    CGRect frame = CGRectZero;
    if (!position || !size || !AXValueGetValue((__bridge AXValueRef)position, kAXValueTypeCGPoint, &frame.origin) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueTypeCGSize, &frame.size) || CGRectIsEmpty(frame)) {
        return CGRectNull;
    }
    return frame;
}

static id FindSidebarOutline(id element, int remainingDepth) {
    if ([AccessibilityString(element, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXOutlineRole]) {
        return element;
    }
    // The simulator's own content can be a large tree and never contains the sidebar.
    if (remainingDepth == 0 || [AccessibilityString(element, kAXSubroleAttribute) isEqualToString:DeviceScreenSubrole]) {
        return nil;
    }
    for (id child in AccessibilityAttribute(element, kAXChildrenAttribute)) {
        id outline = FindSidebarOutline(child, remainingDepth - 1);
        if (outline) {
            return outline;
        }
    }
    return nil;
}

static NSString *DeviceUDIDInRow(id element, int remainingDepth) {
    NSString *identifier = AccessibilityString(element, CFSTR("AXIdentifier"));
    if ([identifier hasPrefix:DeviceRowIdentifierPrefix]) {
        return [identifier substringFromIndex:DeviceRowIdentifierPrefix.length];
    }
    if (remainingDepth == 0) {
        return nil;
    }
    for (id child in AccessibilityAttribute(element, kAXChildrenAttribute)) {
        NSString *udid = DeviceUDIDInRow(child, remainingDepth - 1);
        if (udid) {
            return udid;
        }
    }
    return nil;
}

/// UDID of the device selected in a Device Hub window's sidebar, or nil when the sidebar is hidden.
static NSString *SelectedDeviceUDIDInWindow(id window) {
    NSArray *selectedRows = AccessibilityAttribute(FindSidebarOutline(window, SidebarSearchDepth), kAXSelectedRowsAttribute);
    return selectedRows.count > 0 ? DeviceUDIDInRow(selectedRows.firstObject, RowIdentifierSearchDepth) : nil;
}

/// Simulator screen under a point in a Device Hub window, found by walking up Device Hub's accessibility tree
/// from the element at that point. Returns CGRectNull when the point is not on a simulator screen. When `window`
/// is given, the walk continues to the enclosing window element and returns it there.
static CGRect DeviceHubScreenAtPoint(pid_t deviceHubProcessID, CGPoint point, id *window) {
    id application = CFBridgingRelease(AXUIElementCreateApplication(deviceHubProcessID));
    AXUIElementRef hitElement = NULL;
    if (AXUIElementCopyElementAtPosition((__bridge AXUIElementRef)application, point.x, point.y, &hitElement) != kAXErrorSuccess) {
        return CGRectNull;
    }

    CGRect screenRect = CGRectNull;
    for (id element = CFBridgingRelease(hitElement); element; element = AccessibilityAttribute(element, kAXParentAttribute)) {
        if (CGRectIsNull(screenRect) && [AccessibilityString(element, kAXSubroleAttribute) isEqualToString:DeviceScreenSubrole]) {
            screenRect = AccessibilityFrame(element);
            if (!window) {
                break;
            }
        }
        if (window && [AccessibilityString(element, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXWindowRole]) {
            *window = element;
            break;
        }
    }
    return screenRect;
}

/// Focused window of the focused application when that application is Device Hub, otherwise nil.
static id DeviceHubFocusedWindow(void) {
    id systemWide = CFBridgingRelease(AXUIElementCreateSystemWide());
    id application = AccessibilityAttribute(systemWide, kAXFocusedApplicationAttribute);
    pid_t processID = 0;
    if (!application || AXUIElementGetPid((__bridge AXUIElementRef)application, &processID) != kAXErrorSuccess ||
        !IsDeviceHubProcess(processID)) {
        return nil;
    }
    return AccessibilityAttribute(application, kAXFocusedWindowAttribute);
}

/// Booted simulator matching a Device Hub window title, "<device name> – <runtime name>"; nil when none or ambiguous.
static NSString *DeviceUDIDMatchingWindowTitle(NSString *title) {
    NSArray<NSString *> *titleParts = [title componentsSeparatedByString:@" – "];
    NSString *deviceName = titleParts.firstObject;
    NSString *runtimeName = titleParts.count > 1 ? titleParts[1] : nil;
    NSArray *matches = [BootedDevices() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id device, __unused NSDictionary *bindings) {
        return [[device valueForKey:@"name"] isEqualToString:deviceName] &&
               (!runtimeName || [DeviceRuntimeName(device) isEqualToString:runtimeName]);
    }]];
    return matches.count == 1 ? DeviceUDID(matches.firstObject) : nil;
}

#pragma mark - Routing

/// Maps Device Hub windows to simulators and keeps one touch connection per simulator.
@interface SimulatorRouter : NSObject
/// Simulator used when a Device Hub window cannot be identified; picked in the menu.
@property (nonatomic, copy, nullable) NSString *fallbackUDID;
/// Simulator a Device Hub window shows: its sidebar selection, else its title, else the fallback.
/// `windowID` 0 skips the per-window cache.
- (nullable NSString *)deviceUDIDForWindow:(id)window windowID:(CGWindowID)windowID;
/// Connected sender for the simulator, or nil while it is still connecting; starts connecting when needed.
- (nullable TouchSender *)readySenderForUDID:(NSString *)udid;
- (void)connectBootedDevices;
- (NSString *)connectionStatusForUDID:(NSString *)udid;
@end

@implementation SimulatorRouter {
    NSMutableDictionary<NSString *, TouchSender *> *_sendersByUDID;
    NSMutableSet<NSString *> *_connectingUDIDs;
    /// Device UDID per "<window ID>|<title>"; a title change means the window switched simulators.
    NSMutableDictionary<NSString *, NSString *> *_deviceUDIDByWindowKey;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sendersByUDID = [NSMutableDictionary dictionary];
        _connectingUDIDs = [NSMutableSet set];
        _deviceUDIDByWindowKey = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)deviceUDIDForWindow:(id)window windowID:(CGWindowID)windowID {
    NSString *title = AccessibilityString(window, kAXTitleAttribute) ?: @"";
    NSString *windowKey = windowID ? [NSString stringWithFormat:@"%u|%@", windowID, title] : nil;
    NSString *udid = windowKey ? _deviceUDIDByWindowKey[windowKey] : nil;
    if (!udid) {
        // Two simulators with the same name and runtime differ only in the sidebar, so it takes precedence.
        udid = SelectedDeviceUDIDInWindow(window) ?: DeviceUDIDMatchingWindowTitle(title);
        if (udid && windowKey) {
            _deviceUDIDByWindowKey[windowKey] = udid;
        }
    }
    return udid ?: [self fallbackDeviceUDID];
}

/// The menu's pick if it is booted, else the only booted simulator; nil rather than guessing between several.
- (NSString *)fallbackDeviceUDID {
    if (self.fallbackUDID && IsBooted(DeviceWithUDID(self.fallbackUDID))) {
        return self.fallbackUDID;
    }
    NSArray *bootedDevices = BootedDevices();
    return bootedDevices.count == 1 ? DeviceUDID(bootedDevices.firstObject) : nil;
}

- (TouchSender *)readySenderForUDID:(NSString *)udid {
    TouchSender *sender = _sendersByUDID[udid];
    if (sender.valid) {
        return sender;
    }
    [_sendersByUDID removeObjectForKey:udid];
    id device = DeviceWithUDID(udid);
    if (device) {
        [self connectDevice:device];
    }
    return nil;
}

- (void)connectBootedDevices {
    for (id device in BootedDevices()) {
        [self connectDevice:device];
    }
}

/// Connects off the main thread, since probing `dtuhidd` can take seconds and must never block the event taps.
- (void)connectDevice:(id)device {
    NSString *udid = DeviceUDID(device);
    if (_sendersByUDID[udid].valid || [_connectingUDIDs containsObject:udid]) {
        return;
    }
    [_connectingUDIDs addObject:udid];
    __weak SimulatorRouter *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TouchSender *sender = [[TouchSender alloc] initWithDevice:device];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf didConnectSender:sender udid:udid];
        });
    });
}

- (void)didConnectSender:(TouchSender *)sender udid:(NSString *)udid {
    [_connectingUDIDs removeObject:udid];
    if (!sender) {
        Log([NSString stringWithFormat:@"no touch connection for %@", udid]);
        return;
    }
    Log([NSString stringWithFormat:@"connected to %@", udid]);
    _sendersByUDID[udid] = sender;
}

- (NSString *)connectionStatusForUDID:(NSString *)udid {
    if (_sendersByUDID[udid].valid) {
        return @"ready";
    }
    return [_connectingUDIDs containsObject:udid] ? @"connecting…" : @"unavailable";
}

@end

#pragma mark - Simulator shortcuts

/// Simulator.app keyboard shortcuts restored while Device Hub is frontmost.
typedef NS_ENUM(NSInteger, SimulatorShortcut) {
    /// Command+S: save a screenshot to the Desktop.
    SimulatorShortcutScreenshot,
    /// Command+Shift+A: toggle light and dark appearance.
    SimulatorShortcutToggleAppearance,
};

static BOOL ShortcutForKeyEvent(CGEventRef event, SimulatorShortcut *shortcut) {
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
        return NO;
    }
    CGEventFlags modifiers = CGEventGetFlags(event) &
                             (kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl);
    UniChar characters[4];
    UniCharCount length = 0;
    CGEventKeyboardGetUnicodeString(event, 4, &length, characters);
    // Matched by character, not key code, so the shortcuts follow the keyboard layout like menu key equivalents.
    NSString *key = [[NSString stringWithCharacters:characters length:length] lowercaseString];

    if (modifiers == kCGEventFlagMaskCommand && [key isEqualToString:@"s"]) {
        *shortcut = SimulatorShortcutScreenshot;
        return YES;
    }
    if (modifiers == (kCGEventFlagMaskCommand | kCGEventFlagMaskShift) && [key isEqualToString:@"a"]) {
        *shortcut = SimulatorShortcutToggleAppearance;
        return YES;
    }
    return NO;
}

/// Saves a screenshot to the Desktop with Simulator.app's file name pattern.
static BOOL SaveScreenshotToDesktop(NSString *udid, NSString *deviceName) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    });
    NSString *safeDeviceName = [[deviceName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]]
        componentsJoinedByString:@"-"];
    NSString *fileName = [NSString stringWithFormat:@"Simulator Screenshot - %@ - %@.png", safeDeviceName, [formatter stringFromDate:[NSDate date]]];
    NSURL *desktop = [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
    return RunSimctl(@[ @"io", udid, @"screenshot", [desktop URLByAppendingPathComponent:fileName].path ]) != nil;
}

static BOOL ToggleAppearance(NSString *udid) {
    NSString *current = RunSimctl(@[ @"ui", udid, @"appearance" ]);
    NSString *next = [current isEqualToString:@"dark"] ? @"light" : @"dark";
    return current && RunSimctl(@[ @"ui", udid, @"appearance", next ]);
}

#pragma mark - Interactive mode

static const CGFloat FingerDotDiameter = 28;

/// Minimum time between accessibility lookups while hovering over Device Hub outside a simulator screen.
static const NSTimeInterval HoverLookupIntervalSeconds = 0.05;

/// Draws the two simulated fingers over a simulator screen, inset by half a dot so dots at the edge stay visible.
@interface FingerOverlayView : NSView
@property (nonatomic) FingerPair fingers;
@property (nonatomic) BOOL pressed;
@end

@implementation FingerOverlayView

- (void)drawRect:(__unused NSRect)dirtyRect {
    NSRect screen = NSInsetRect(self.bounds, FingerDotDiameter / 2, FingerDotDiameter / 2);
    [[NSColor colorWithWhite:self.pressed ? 0.2 : 0.5 alpha:0.5] setFill];
    for (NSValue *finger in @[ [NSValue valueWithPoint:self.fingers.first], [NSValue valueWithPoint:self.fingers.second] ]) {
        NSPoint position = finger.pointValue;
        NSPoint center = NSMakePoint(NSMinX(screen) + position.x * NSWidth(screen), NSMaxY(screen) - position.y * NSHeight(screen));
        NSRect dot = NSMakeRect(center.x - FingerDotDiameter / 2, center.y - FingerDotDiameter / 2, FingerDotDiameter, FingerDotDiameter);
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
}

@end

/// Turns Option+drag over a simulator screen in Device Hub into two-finger touches, and handles restored shortcuts.
@interface InteractiveController : NSObject
- (instancetype)initWithRouter:(SimulatorRouter *)router;
/// Called on the main thread once the event taps run, after Accessibility permission is granted.
@property (nonatomic, copy, nullable) void (^listeningDidStart)(void);
@property (nonatomic, readonly) BOOL listening;
- (void)start;
/// Lifts both fingers if a gesture is in progress, so the simulator is never left with a stuck touch.
- (void)cancelTouch;
@end

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
    if (AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)promptOptions)) {
        [self startListening];
        return;
    }
    Log(@"waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)");
    __weak InteractiveController *weakSelf = self;
    _permissionPollTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        if (AXIsProcessTrusted()) {
            [timer invalidate];
            [weakSelf startListening];
        }
    }];
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
        return;
    }
    if (self.listeningDidStart) {
        self.listeningDidStart();
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
            CGEventTapEnable(_gestureTap, true);
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
    [self showFingers:fingers screenRect:_gestureScreenRect pressed:eventType != NSEventTypeLeftMouseUp];
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

#pragma mark - Status bar app

/// Menu bar front end: shows connection state, the fallback simulator and the available gestures.
@interface StatusBarController : NSObject <NSMenuDelegate>
@end

@implementation StatusBarController {
    SimulatorRouter *_router;
    InteractiveController *_interactiveController;
    NSStatusItem *_statusItem;
}

- (instancetype)init {
    if ((self = [super init])) {
        _router = [SimulatorRouter new];
        _interactiveController = [[InteractiveController alloc] initWithRouter:_router];
        __weak StatusBarController *weakSelf = self;
        _interactiveController.listeningDidStart = ^{
            [weakSelf updateIcon];
        };

        _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSMenu *menu = [NSMenu new];
        menu.delegate = self;
        _statusItem.menu = menu;

        [_router connectBootedDevices];
        [_interactiveController start];
        [self updateIcon];
    }
    return self;
}

- (void)updateIcon {
    NSString *symbolName = _interactiveController.listening ? @"hand.raised.fingers.spread.fill" : @"hand.raised.fingers.spread";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:@"HubTouch"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.title = image ? @"" : @"HubTouch";
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];

    BOOL needsPermission = NO;
    if (!_interactiveController.listening) {
        [menu addItem:[self itemWithTitle:@"Grant Accessibility Permission…" action:@selector(openAccessibilitySettings)]];
        needsPermission = YES;
    }
    if (!CGPreflightListenEventAccess()) {
        [menu addItem:[self itemWithTitle:@"Grant Input Monitoring Permission…" action:@selector(openInputMonitoringSettings)]];
        needsPermission = YES;
    }
    if (needsPermission) {
        [menu addItem:NSMenuItem.separatorItem];
    }

    [menu addItem:[self sectionHeaderWithTitle:@"Booted Simulators"]];
    [_router connectBootedDevices];
    NSArray *bootedDevices = [BootedDevices() sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
        return [DeviceTitle(first) localizedStandardCompare:DeviceTitle(second)];
    }];
    for (id device in bootedDevices) {
        NSString *udid = DeviceUDID(device);
        NSString *title = [NSString stringWithFormat:@"%@ · %@", DeviceTitle(device), [_router connectionStatusForUDID:udid]];
        NSMenuItem *item = [self itemWithTitle:title action:@selector(toggleFallbackFromMenuItem:)];
        item.representedObject = udid;
        item.toolTip = udid;
        item.state = [udid isEqualToString:_router.fallbackUDID] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    if (bootedDevices.count == 0) {
        [menu addItem:[self disabledItemWithTitle:@"No booted simulators"]];
    }
    [menu addItem:[self disabledItemWithTitle:@"Checked: used when a window can't be identified"]];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self sectionHeaderWithTitle:@"Gestures (as in Simulator.app)"]];
    [menu addItem:[self disabledItemWithTitle:@"Option: show two touch points"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+click: two-finger tap"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+drag: pinch / rotate"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+Shift: move pinch center"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+Shift+drag: two-finger drag"]];
    [menu addItem:[self sectionHeaderWithTitle:@"Shortcuts in Device Hub"]];
    [menu addItem:[self disabledItemWithTitle:@"Command+S: screenshot to Desktop"]];
    [menu addItem:[self disabledItemWithTitle:@"Command+Shift+A: toggle appearance"]];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quitItem = [self itemWithTitle:@"Quit HubTouch" action:@selector(quit)];
    quitItem.keyEquivalent = @"q";
    [menu addItem:quitItem];
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenuItem *)disabledItemWithTitle:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)sectionHeaderWithTitle:(NSString *)title {
    if (@available(macOS 14, *)) {
        return [NSMenuItem sectionHeaderWithTitle:title];
    }
    return [self disabledItemWithTitle:title];
}

- (void)toggleFallbackFromMenuItem:(NSMenuItem *)item {
    NSString *udid = item.representedObject;
    _router.fallbackUDID = [udid isEqualToString:_router.fallbackUDID] ? nil : udid;
}

- (void)openAccessibilitySettings {
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)openInputMonitoringSettings {
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)quit {
    [_interactiveController cancelTouch];
    [NSApp terminate:nil];
}

@end

#pragma mark - Command line

static double DoubleOption(NSDictionary<NSString *, NSString *> *options, NSString *name, double fallback) {
    NSString *value = options[name];
    return value ? value.doubleValue : fallback;
}

static void PrintUsage(void) {
    fprintf(stderr,
            "usage: hubtouch <gesture> --udid UDID [options]\n"
            "  coordinates are 0...1 ratios of the screen; defaults in brackets\n"
            "  pinch   --from R [0.05] --to R [0.25]   finger distance from center (to > from zooms in)\n"
            "  rotate  --radius R [0.15] --degrees D [90]\n"
            "  twotap  --spread R [0.05]\n"
            "  twopan  --dx X [0] --dy Y [-0.3] --spread R [0.05]\n"
            "  common  --x X [0.5] --y Y [0.5] --steps N [20]\n"
            "  For interactive gestures in Device Hub, open HubTouch.app.\n");
}

static void RunStatusBarApp(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    StatusBarController *statusBarController __attribute__((objc_precise_lifetime)) = [StatusBarController new];
    [NSApp run];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LoadCoreSimulator();
        if (argc < 2 && [NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) {
            RunStatusBarApp();
            return 0;
        }
        if (argc < 2) {
            PrintUsage();
            return 1;
        }

        NSString *gesture = @(argv[1]);
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        for (int index = 2; index + 1 < argc; index += 2) {
            NSString *key = @(argv[index]);
            if (![key hasPrefix:@"--"]) {
                PrintUsage();
                return 1;
            }
            options[[key substringFromIndex:2]] = @(argv[index + 1]);
        }

        NSString *udid = options[@"udid"];
        if (!udid) {
            PrintUsage();
            return 1;
        }
        id device = DeviceWithUDID(udid);
        if (!device || !IsBooted(device)) {
            Fail([NSString stringWithFormat:@"no booted simulator with UDID %@", udid]);
        }
        TouchSender *sender = [[TouchSender alloc] initWithDevice:device];
        if (!sender) {
            Fail(@"the simulator's dtuhidd did not answer");
        }

        CGPoint center = CGPointMake(DoubleOption(options, @"x", 0.5), DoubleOption(options, @"y", 0.5));
        int steps = (int)DoubleOption(options, @"steps", DefaultStepCount);

        if ([gesture isEqualToString:@"pinch"]) {
            double fromRadius = DoubleOption(options, @"from", 0.05);
            double toRadius = DoubleOption(options, @"to", 0.25);
            [sender performPath:^FingerPair(double progress) {
                return MirroredFingers(center, fromRadius + (toRadius - fromRadius) * progress, M_PI_4);
            } steps:steps];
        } else if ([gesture isEqualToString:@"rotate"]) {
            double radius = DoubleOption(options, @"radius", 0.15);
            double sweepRadians = DoubleOption(options, @"degrees", 90) * M_PI / 180;
            [sender performPath:^FingerPair(double progress) {
                return MirroredFingers(center, radius, sweepRadians * progress);
            } steps:steps];
        } else if ([gesture isEqualToString:@"twotap"]) {
            double spread = DoubleOption(options, @"spread", 0.05);
            [sender performPath:^FingerPair(__unused double progress) {
                return MirroredFingers(center, spread, 0);
            } steps:1];
        } else if ([gesture isEqualToString:@"twopan"]) {
            double deltaX = DoubleOption(options, @"dx", 0);
            double deltaY = DoubleOption(options, @"dy", -0.3);
            double spread = DoubleOption(options, @"spread", 0.05);
            [sender performPath:^FingerPair(double progress) {
                CGPoint movedCenter = CGPointMake(center.x + deltaX * progress, center.y + deltaY * progress);
                return MirroredFingers(movedCenter, spread, 0);
            } steps:steps];
        } else {
            PrintUsage();
            return 1;
        }
    }
    return 0;
}

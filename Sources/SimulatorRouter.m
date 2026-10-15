//
//  SimulatorRouter.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "SimulatorRouter.h"
#import "CoreSimulator.h"
#import "DeviceHub.h"
#import "Support.h"
#import "TouchSender.h"

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

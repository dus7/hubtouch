//
//  CoreSimulator.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "CoreSimulator.h"
#import "Support.h"
#import <dlfcn.h>
#import <objc/message.h>

/// SimDeviceState value for a booted simulator.
static const NSUInteger SimDeviceStateBooted = 3;

void LoadCoreSimulator(void) {
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

NSString *DeviceUDID(id device) {
    return [[device valueForKey:@"UDID"] UUIDString];
}

BOOL IsBooted(id device) {
    return [[device valueForKey:@"state"] unsignedIntegerValue] == SimDeviceStateBooted;
}

id DeviceWithUDID(NSString *udid) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    return uuid ? [DefaultDeviceSet() valueForKey:@"devicesByUDID"][uuid] : nil;
}

NSArray *BootedDevices(void) {
    NSArray *devices = [[DefaultDeviceSet() valueForKey:@"devicesByUDID"] allValues];
    return [devices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id device, __unused NSDictionary *bindings) {
        return IsBooted(device);
    }]];
}

NSString *DeviceRuntimeName(id device) {
    @try {
        return [device valueForKeyPath:@"runtime.name"];
    } @catch (__unused NSException *exception) {
        // The runtime only refines matching and labels; the device name alone still works.
        return nil;
    }
}

NSString *DeviceTitle(id device) {
    NSString *name = [device valueForKey:@"name"];
    NSString *runtimeName = DeviceRuntimeName(device);
    return runtimeName ? [NSString stringWithFormat:@"%@ (%@)", name, runtimeName] : name;
}

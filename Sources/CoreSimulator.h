//
//  CoreSimulator.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void LoadCoreSimulator(void);

NSString *_Nullable DeviceUDID(id device);

BOOL IsBooted(id device);

id _Nullable DeviceWithUDID(NSString *udid);

NSArray *BootedDevices(void);

NSString *_Nullable DeviceRuntimeName(id device);

NSString *DeviceTitle(id device);

NS_ASSUME_NONNULL_END

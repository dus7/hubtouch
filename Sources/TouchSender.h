//
//  TouchSender.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <AppKit/AppKit.h>
#import "Fingers.h"

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END

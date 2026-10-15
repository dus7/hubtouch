//
//  InteractiveController.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <Foundation/Foundation.h>

@class SimulatorRouter;

NS_ASSUME_NONNULL_BEGIN

/// Turns Option+drag over a simulator screen in Device Hub into two-finger touches, and handles restored shortcuts.
@interface InteractiveController : NSObject
- (instancetype)initWithRouter:(SimulatorRouter *)router;
/// Called on the main thread when the event taps start or stop as Accessibility permission comes and goes.
@property (nonatomic, copy, nullable) void (^listeningDidChange)(void);
@property (nonatomic, readonly) BOOL listening;
- (void)start;
/// Lifts both fingers if a gesture is in progress, so the simulator is never left with a stuck touch.
- (void)cancelTouch;
@end

NS_ASSUME_NONNULL_END

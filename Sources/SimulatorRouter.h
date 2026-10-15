//
//  SimulatorRouter.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class TouchSender;

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END

//
//  FingerOverlayView.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <AppKit/AppKit.h>
#import "Fingers.h"

NS_ASSUME_NONNULL_BEGIN

/// Diameter of a drawn finger dot, in points.
extern const CGFloat FingerDotDiameter;

/// Draws the two simulated fingers over a simulator screen, inset by half a dot so dots at the edge stay visible.
@interface FingerOverlayView : NSView
@property (nonatomic) FingerPair fingers;
@property (nonatomic) BOOL pressed;
@end

NS_ASSUME_NONNULL_END

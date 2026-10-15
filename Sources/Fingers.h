//
//  Fingers.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pair of finger positions in normalized 0...1 screen space, origin at the top left.
typedef struct {
    CGPoint first;
    CGPoint second;
} FingerPair;

/// Gesture expressed as finger positions over progress 0...1.
typedef FingerPair (^GesturePath)(double progress);

CGPoint ClampToUnitSquare(CGPoint point);

/// Location in global display coordinates expressed in the normalized space of the screen rect.
CGPoint NormalizedPoint(CGPoint location, CGRect screenRect);

FingerPair MirroredFingers(CGPoint center, double radius, double angleRadians);

NS_ASSUME_NONNULL_END

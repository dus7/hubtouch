//
//  Fingers.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "Fingers.h"
#import <math.h>

CGPoint ClampToUnitSquare(CGPoint point) {
    return CGPointMake(MIN(MAX(point.x, 0), 1), MIN(MAX(point.y, 0), 1));
}

CGPoint NormalizedPoint(CGPoint location, CGRect screenRect) {
    return ClampToUnitSquare(CGPointMake((location.x - screenRect.origin.x) / screenRect.size.width,
                                         (location.y - screenRect.origin.y) / screenRect.size.height));
}

FingerPair MirroredFingers(CGPoint center, double radius, double angleRadians) {
    CGFloat offsetX = radius * cos(angleRadians);
    CGFloat offsetY = radius * sin(angleRadians);
    return (FingerPair){
        .first = CGPointMake(center.x - offsetX, center.y - offsetY),
        .second = CGPointMake(center.x + offsetX, center.y + offsetY),
    };
}

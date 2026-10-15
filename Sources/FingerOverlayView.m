//
//  FingerOverlayView.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "FingerOverlayView.h"

const CGFloat FingerDotDiameter = 28;


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

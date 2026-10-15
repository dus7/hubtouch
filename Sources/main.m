//
//  main.m
//  HubTouch
//
//  Restores two-finger touch input and Simulator.app shortcuts for iOS Simulators shown in Xcode 27's Device Hub,
//  through CoreSimulator's private `dtuhidd` HID service.
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <AppKit/AppKit.h>
#import "CoreSimulator.h"
#import "Fingers.h"
#import "StatusBarController.h"
#import "Support.h"
#import "TouchSender.h"

static const int DefaultStepCount = 20;

static double DoubleOption(NSDictionary<NSString *, NSString *> *options, NSString *name, double fallback) {
    NSString *value = options[name];
    return value ? value.doubleValue : fallback;
}

static void PrintUsage(void) {
    fprintf(stderr,
            "usage: hubtouch <gesture> --udid UDID [options]\n"
            "  coordinates are 0...1 ratios of the screen; defaults in brackets\n"
            "  pinch   --from R [0.05] --to R [0.25]   finger distance from center (to > from zooms in)\n"
            "  rotate  --radius R [0.15] --degrees D [90]\n"
            "  twotap  --spread R [0.05]\n"
            "  twopan  --dx X [0] --dy Y [-0.3] --spread R [0.05]\n"
            "  common  --x X [0.5] --y Y [0.5] --steps N [20]\n"
            "  For interactive gestures in Device Hub, open HubTouch.app.\n");
}

static void RunStatusBarApp(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    StatusBarController *statusBarController __attribute__((objc_precise_lifetime)) = [StatusBarController new];
    [NSApp run];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LoadCoreSimulator();
        if (argc < 2 && [NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) {
            RunStatusBarApp();
            return 0;
        }
        if (argc < 2) {
            PrintUsage();
            return 1;
        }

        NSString *gesture = @(argv[1]);
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        for (int index = 2; index + 1 < argc; index += 2) {
            NSString *key = @(argv[index]);
            if (![key hasPrefix:@"--"]) {
                PrintUsage();
                return 1;
            }
            options[[key substringFromIndex:2]] = @(argv[index + 1]);
        }

        NSString *udid = options[@"udid"];
        if (!udid) {
            PrintUsage();
            return 1;
        }
        id device = DeviceWithUDID(udid);
        if (!device || !IsBooted(device)) {
            Fail([NSString stringWithFormat:@"no booted simulator with UDID %@", udid]);
        }
        TouchSender *sender = [[TouchSender alloc] initWithDevice:device];
        if (!sender) {
            Fail(@"the simulator's dtuhidd did not answer");
        }

        CGPoint center = CGPointMake(DoubleOption(options, @"x", 0.5), DoubleOption(options, @"y", 0.5));
        int steps = (int)DoubleOption(options, @"steps", DefaultStepCount);

        if ([gesture isEqualToString:@"pinch"]) {
            double fromRadius = DoubleOption(options, @"from", 0.05);
            double toRadius = DoubleOption(options, @"to", 0.25);
            [sender performPath:^FingerPair(double progress) {
                return MirroredFingers(center, fromRadius + (toRadius - fromRadius) * progress, M_PI_4);
            } steps:steps];
        } else if ([gesture isEqualToString:@"rotate"]) {
            double radius = DoubleOption(options, @"radius", 0.15);
            double sweepRadians = DoubleOption(options, @"degrees", 90) * M_PI / 180;
            [sender performPath:^FingerPair(double progress) {
                return MirroredFingers(center, radius, sweepRadians * progress);
            } steps:steps];
        } else if ([gesture isEqualToString:@"twotap"]) {
            double spread = DoubleOption(options, @"spread", 0.05);
            [sender performPath:^FingerPair(__unused double progress) {
                return MirroredFingers(center, spread, 0);
            } steps:1];
        } else if ([gesture isEqualToString:@"twopan"]) {
            double deltaX = DoubleOption(options, @"dx", 0);
            double deltaY = DoubleOption(options, @"dy", -0.3);
            double spread = DoubleOption(options, @"spread", 0.05);
            [sender performPath:^FingerPair(double progress) {
                CGPoint movedCenter = CGPointMake(center.x + deltaX * progress, center.y + deltaY * progress);
                return MirroredFingers(movedCenter, spread, 0);
            } steps:steps];
        } else {
            PrintUsage();
            return 1;
        }
    }
    return 0;
}

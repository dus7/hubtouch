//
//  SimulatorShortcuts.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "SimulatorShortcuts.h"
#import "Support.h"

BOOL ShortcutForKeyEvent(CGEventRef event, SimulatorShortcut *shortcut) {
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
        return NO;
    }
    CGEventFlags modifiers = CGEventGetFlags(event) &
                             (kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl);
    UniChar characters[4];
    UniCharCount length = 0;
    CGEventKeyboardGetUnicodeString(event, 4, &length, characters);
    // Matched by character, not key code, so the shortcuts follow the keyboard layout like menu key equivalents.
    NSString *key = [[NSString stringWithCharacters:characters length:length] lowercaseString];

    if (modifiers == kCGEventFlagMaskCommand && [key isEqualToString:@"s"]) {
        *shortcut = SimulatorShortcutScreenshot;
        return YES;
    }
    if (modifiers == (kCGEventFlagMaskCommand | kCGEventFlagMaskShift) && [key isEqualToString:@"a"]) {
        *shortcut = SimulatorShortcutToggleAppearance;
        return YES;
    }
    return NO;
}

BOOL SaveScreenshotToDesktop(NSString *udid, NSString *deviceName) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    });
    NSString *safeDeviceName = [[deviceName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]]
        componentsJoinedByString:@"-"];
    NSString *fileName = [NSString stringWithFormat:@"Simulator Screenshot - %@ - %@.png", safeDeviceName, [formatter stringFromDate:[NSDate date]]];
    NSURL *desktop = [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
    return RunSimctl(@[ @"io", udid, @"screenshot", [desktop URLByAppendingPathComponent:fileName].path ]) != nil;
}

BOOL ToggleAppearance(NSString *udid) {
    NSString *current = RunSimctl(@[ @"ui", udid, @"appearance" ]);
    NSString *next = [current isEqualToString:@"dark"] ? @"light" : @"dark";
    return current && RunSimctl(@[ @"ui", udid, @"appearance", next ]);
}

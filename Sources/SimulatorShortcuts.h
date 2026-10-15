//
//  SimulatorShortcuts.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Simulator.app keyboard shortcuts restored while Device Hub is frontmost.
typedef NS_ENUM(NSInteger, SimulatorShortcut) {
    /// Command+S: save a screenshot to the Desktop.
    SimulatorShortcutScreenshot,
    /// Command+Shift+A: toggle light and dark appearance.
    SimulatorShortcutToggleAppearance,
};

BOOL ShortcutForKeyEvent(CGEventRef event, SimulatorShortcut *shortcut);

/// Saves a screenshot to the Desktop with Simulator.app's file name pattern.
BOOL SaveScreenshotToDesktop(NSString *udid, NSString *deviceName);

BOOL ToggleAppearance(NSString *udid);

NS_ASSUME_NONNULL_END

//
//  DeviceHub.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

/// Bundle identifier of Xcode's Device Hub app.
extern NSString *const DeviceHubBundleIdentifier;

BOOL IsDeviceHubProcess(pid_t processID);

/// Topmost normal window under a point in global display coordinates.
BOOL TopmostWindowAtPoint(CGPoint point, CGWindowID *windowID, pid_t *ownerProcessID);

NSString *_Nullable AccessibilityString(id _Nullable element, CFStringRef attribute);

/// UDID of the device selected in a Device Hub window's sidebar, or nil when the sidebar is hidden.
NSString *_Nullable SelectedDeviceUDIDInWindow(id _Nullable window);

/// Simulator screen under a point in a Device Hub window, found by walking up Device Hub's accessibility tree
/// from the element at that point. Returns CGRectNull when the point is not on a simulator screen. When `window`
/// is given, the walk continues to the enclosing window element and returns it there.
CGRect DeviceHubScreenAtPoint(pid_t deviceHubProcessID, CGPoint point, id _Nullable __autoreleasing *_Nullable window);

/// Focused window of the focused application when that application is Device Hub, otherwise nil.
id _Nullable DeviceHubFocusedWindow(void);

/// Booted simulator matching a Device Hub window title, "<device name> – <runtime name>"; nil when none or ambiguous.
NSString *_Nullable DeviceUDIDMatchingWindowTitle(NSString *title);

NS_ASSUME_NONNULL_END

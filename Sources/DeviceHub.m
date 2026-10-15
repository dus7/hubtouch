//
//  DeviceHub.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "DeviceHub.h"
#import "CoreSimulator.h"

NSString *const DeviceHubBundleIdentifier = @"com.apple.dt.Devices";

/// Accessibility subrole Device Hub gives the view showing a simulator's screen.
static NSString *const DeviceScreenSubrole = @"iOSContentGroup";

/// Prefix of the accessibility identifier on Device Hub sidebar rows; the device UDID follows it.
static NSString *const DeviceRowIdentifierPrefix = @"TableRow.Device.";

/// Depth limits for searching a Device Hub window; the sidebar sits near the top of its tree.
static const int SidebarSearchDepth = 10;
static const int RowIdentifierSearchDepth = 4;

BOOL IsDeviceHubProcess(pid_t processID) {
    static pid_t deviceHubProcessID;
    if (processID == deviceHubProcessID) {
        return YES;
    }
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:processID];
    if (![application.bundleIdentifier isEqualToString:DeviceHubBundleIdentifier]) {
        return NO;
    }
    deviceHubProcessID = processID;
    return YES;
}

BOOL TopmostWindowAtPoint(CGPoint point, CGWindowID *windowID, pid_t *ownerProcessID) {
    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        CGRect bounds;
        if ([window[(__bridge NSString *)kCGWindowLayer] integerValue] != 0 ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds) ||
            !CGRectContainsPoint(bounds, point)) {
            continue;
        }
        *windowID = [window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
        *ownerProcessID = [window[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        return YES;
    }
    return NO;
}

static id AccessibilityAttribute(id element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (!element || AXUIElementCopyAttributeValue((__bridge AXUIElementRef)element, attribute, &value) != kAXErrorSuccess) {
        return nil;
    }
    return CFBridgingRelease(value);
}

NSString *AccessibilityString(id element, CFStringRef attribute) {
    id value = AccessibilityAttribute(element, attribute);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static CGRect AccessibilityFrame(id element) {
    id position = AccessibilityAttribute(element, kAXPositionAttribute);
    id size = AccessibilityAttribute(element, kAXSizeAttribute);
    CGRect frame = CGRectZero;
    if (!position || !size || !AXValueGetValue((__bridge AXValueRef)position, kAXValueTypeCGPoint, &frame.origin) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueTypeCGSize, &frame.size) || CGRectIsEmpty(frame)) {
        return CGRectNull;
    }
    return frame;
}

static id FindSidebarOutline(id element, int remainingDepth) {
    if ([AccessibilityString(element, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXOutlineRole]) {
        return element;
    }
    // The simulator's own content can be a large tree and never contains the sidebar.
    if (remainingDepth == 0 || [AccessibilityString(element, kAXSubroleAttribute) isEqualToString:DeviceScreenSubrole]) {
        return nil;
    }
    for (id child in AccessibilityAttribute(element, kAXChildrenAttribute)) {
        id outline = FindSidebarOutline(child, remainingDepth - 1);
        if (outline) {
            return outline;
        }
    }
    return nil;
}

static NSString *DeviceUDIDInRow(id element, int remainingDepth) {
    NSString *identifier = AccessibilityString(element, CFSTR("AXIdentifier"));
    if ([identifier hasPrefix:DeviceRowIdentifierPrefix]) {
        return [identifier substringFromIndex:DeviceRowIdentifierPrefix.length];
    }
    if (remainingDepth == 0) {
        return nil;
    }
    for (id child in AccessibilityAttribute(element, kAXChildrenAttribute)) {
        NSString *udid = DeviceUDIDInRow(child, remainingDepth - 1);
        if (udid) {
            return udid;
        }
    }
    return nil;
}

NSString *SelectedDeviceUDIDInWindow(id window) {
    NSArray *selectedRows = AccessibilityAttribute(FindSidebarOutline(window, SidebarSearchDepth), kAXSelectedRowsAttribute);
    return selectedRows.count > 0 ? DeviceUDIDInRow(selectedRows.firstObject, RowIdentifierSearchDepth) : nil;
}

CGRect DeviceHubScreenAtPoint(pid_t deviceHubProcessID, CGPoint point, id *window) {
    id application = CFBridgingRelease(AXUIElementCreateApplication(deviceHubProcessID));
    AXUIElementRef hitElement = NULL;
    if (AXUIElementCopyElementAtPosition((__bridge AXUIElementRef)application, point.x, point.y, &hitElement) != kAXErrorSuccess) {
        return CGRectNull;
    }

    CGRect screenRect = CGRectNull;
    for (id element = CFBridgingRelease(hitElement); element; element = AccessibilityAttribute(element, kAXParentAttribute)) {
        if (CGRectIsNull(screenRect) && [AccessibilityString(element, kAXSubroleAttribute) isEqualToString:DeviceScreenSubrole]) {
            screenRect = AccessibilityFrame(element);
            if (!window) {
                break;
            }
        }
        if (window && [AccessibilityString(element, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXWindowRole]) {
            *window = element;
            break;
        }
    }
    return screenRect;
}

id DeviceHubFocusedWindow(void) {
    id systemWide = CFBridgingRelease(AXUIElementCreateSystemWide());
    id application = AccessibilityAttribute(systemWide, kAXFocusedApplicationAttribute);
    pid_t processID = 0;
    if (!application || AXUIElementGetPid((__bridge AXUIElementRef)application, &processID) != kAXErrorSuccess ||
        !IsDeviceHubProcess(processID)) {
        return nil;
    }
    return AccessibilityAttribute(application, kAXFocusedWindowAttribute);
}

NSString *DeviceUDIDMatchingWindowTitle(NSString *title) {
    NSArray<NSString *> *titleParts = [title componentsSeparatedByString:@" – "];
    NSString *deviceName = titleParts.firstObject;
    NSString *runtimeName = titleParts.count > 1 ? titleParts[1] : nil;
    NSArray *matches = [BootedDevices() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id device, __unused NSDictionary *bindings) {
        return [[device valueForKey:@"name"] isEqualToString:deviceName] &&
               (!runtimeName || [DeviceRuntimeName(device) isEqualToString:runtimeName]);
    }]];
    return matches.count == 1 ? DeviceUDID(matches.firstObject) : nil;
}

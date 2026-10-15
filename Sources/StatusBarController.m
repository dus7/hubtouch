//
//  StatusBarController.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "StatusBarController.h"
#import "CoreSimulator.h"
#import "InteractiveController.h"
#import "SimulatorRouter.h"
#import "Support.h"

@implementation StatusBarController {
    SimulatorRouter *_router;
    InteractiveController *_interactiveController;
    NSStatusItem *_statusItem;
}

- (instancetype)init {
    if ((self = [super init])) {
        _router = [SimulatorRouter new];
        _interactiveController = [[InteractiveController alloc] initWithRouter:_router];
        __weak StatusBarController *weakSelf = self;
        _interactiveController.listeningDidChange = ^{
            [weakSelf updateIcon];
        };

        _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSMenu *menu = [NSMenu new];
        menu.delegate = self;
        _statusItem.menu = menu;

        [_router connectBootedDevices];
        [_interactiveController start];
        [self updateIcon];
    }
    return self;
}

- (void)updateIcon {
    NSString *symbolName = _interactiveController.listening ? @"hand.raised.fingers.spread.fill" : @"hand.raised.fingers.spread";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:@"HubTouch"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.title = image ? @"" : @"HubTouch";
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];

    BOOL needsPermission = NO;
    if (!_interactiveController.listening) {
        [menu addItem:[self itemWithTitle:@"Grant Accessibility Permission…" action:@selector(openAccessibilitySettings)]];
        needsPermission = YES;
    }
    if (!CGPreflightListenEventAccess()) {
        [menu addItem:[self itemWithTitle:@"Grant Input Monitoring Permission…" action:@selector(openInputMonitoringSettings)]];
        needsPermission = YES;
    }
    if (needsPermission) {
        // macOS applies Input Monitoring only to newly launched processes, so a grant needs a relaunch to take effect.
        [menu addItem:[self itemWithTitle:@"Relaunch HubTouch" action:@selector(relaunch)]];
        [menu addItem:NSMenuItem.separatorItem];
    }

    [menu addItem:[self sectionHeaderWithTitle:@"Booted Simulators"]];
    [_router connectBootedDevices];
    NSArray *bootedDevices = [BootedDevices() sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
        return [DeviceTitle(first) localizedStandardCompare:DeviceTitle(second)];
    }];
    for (id device in bootedDevices) {
        NSString *udid = DeviceUDID(device);
        NSString *title = [NSString stringWithFormat:@"%@ · %@", DeviceTitle(device), [_router connectionStatusForUDID:udid]];
        NSMenuItem *item = [self itemWithTitle:title action:@selector(toggleFallbackFromMenuItem:)];
        item.representedObject = udid;
        item.toolTip = udid;
        item.state = [udid isEqualToString:_router.fallbackUDID] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    if (bootedDevices.count == 0) {
        [menu addItem:[self disabledItemWithTitle:@"No booted simulators"]];
    }
    [menu addItem:[self disabledItemWithTitle:@"Checked: used when a window can't be identified"]];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self sectionHeaderWithTitle:@"Gestures (as in Simulator.app)"]];
    [menu addItem:[self disabledItemWithTitle:@"Option: show two touch points"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+click: two-finger tap"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+drag: pinch / rotate"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+Shift: move pinch center"]];
    [menu addItem:[self disabledItemWithTitle:@"Option+Shift+drag: two-finger drag"]];
    [menu addItem:[self sectionHeaderWithTitle:@"Shortcuts in Device Hub"]];
    [menu addItem:[self disabledItemWithTitle:@"Command+S: screenshot to Desktop"]];
    [menu addItem:[self disabledItemWithTitle:@"Command+Shift+A: toggle appearance"]];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quitItem = [self itemWithTitle:@"Quit HubTouch" action:@selector(quit)];
    quitItem.keyEquivalent = @"q";
    [menu addItem:quitItem];
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenuItem *)disabledItemWithTitle:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)sectionHeaderWithTitle:(NSString *)title {
    if (@available(macOS 14, *)) {
        return [NSMenuItem sectionHeaderWithTitle:title];
    }
    return [self disabledItemWithTitle:title];
}

- (void)toggleFallbackFromMenuItem:(NSMenuItem *)item {
    NSString *udid = item.representedObject;
    _router.fallbackUDID = [udid isEqualToString:_router.fallbackUDID] ? nil : udid;
}

- (void)openAccessibilitySettings {
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)openInputMonitoringSettings {
    // Registers HubTouch in the Input Monitoring list (prompting the first time), so there is a switch to turn on.
    CGRequestListenEventAccess();
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)relaunch {
    [_interactiveController cancelTouch];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL
                                        configuration:configuration
                                    completionHandler:^(__unused NSRunningApplication *application, NSError *error) {
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            if (error) {
                                                Log([NSString stringWithFormat:@"relaunch failed: %@", error]);
                                                return;
                                            }
                                            [NSApp terminate:nil];
                                        });
                                    }];
}

- (void)quit {
    [_interactiveController cancelTouch];
    [NSApp terminate:nil];
}

@end

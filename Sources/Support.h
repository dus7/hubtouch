//
//  Support.h
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void Log(NSString *message);

void Fail(NSString *message);

void BeepOnMainQueue(void);

/// The Xcode selected with `xcode-select`. DEVELOPER_DIR is ignored on purpose: it would let another process choose
/// which `simctl` runs with HubTouch's permissions.
NSString *_Nullable ActiveDeveloperDirectory(void);

NSString *_Nullable RunSimctl(NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END

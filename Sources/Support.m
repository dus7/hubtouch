//
//  Support.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "Support.h"
#import <AppKit/AppKit.h>

void Log(NSString *message) {
    fprintf(stderr, "hubtouch: %s\n", message.UTF8String);
}

void Fail(NSString *message) {
    Log(message);
    exit(1);
}

void BeepOnMainQueue(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSBeep();
    });
}

/// Runs a command-line tool and returns its trimmed standard output, or nil if it cannot run or exits with an error.
static NSString *RunTool(NSString *executablePath, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments;
    // Tools run with HubTouch's privacy permissions, so they must not be steerable through inherited variables
    // such as DEVELOPER_DIR or DYLD_*.
    task.environment = @{ @"HOME" : NSHomeDirectory(), @"PATH" : @"/usr/bin:/bin:/usr/sbin:/sbin" };
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) {
        return nil;
    }
    // Read before waiting, so a full pipe cannot keep the tool from exiting.
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        Log([NSString stringWithFormat:@"%@ %@ failed", executablePath.lastPathComponent, [arguments componentsJoinedByString:@" "]]);
        return nil;
    }
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *ActiveDeveloperDirectory(void) {
    static NSString *developerDirectory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        developerDirectory = RunTool(@"/usr/bin/xcode-select", @[ @"-p" ]);
    });
    return developerDirectory;
}

NSString *RunSimctl(NSArray<NSString *> *arguments) {
    NSString *developerDirectory = ActiveDeveloperDirectory();
    return developerDirectory ? RunTool([developerDirectory stringByAppendingPathComponent:@"usr/bin/simctl"], arguments) : nil;
}

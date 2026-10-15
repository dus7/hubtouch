//
//  TouchSender.m
//  HubTouch
//
//  Copyright 2026 dus7
//  Licensed under the Apache License, Version 2.0; see LICENSE.
//

#import "TouchSender.h"
#import "Support.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <xpc/xpc.h>

/// Guest HID service that receives digitizer events from the host.
static NSString *const DigitizerServiceName = @"com.apple.coredevice.feature.remote.hid.digitizer";

/// Deadline for `dtuhidd` to answer a barrier; the first one may have to launch the daemon.
static const int64_t DigitizerBarrierTimeoutNanoseconds = 4 * NSEC_PER_SEC;

/// Time for `dtuhidd` to open the device after it first answers.
static const useconds_t DigitizerActivationDelayMicroseconds = 200000;

/// Pace of scripted gestures, about one display frame per step.
static const useconds_t GestureStepIntervalMicroseconds = 16000;


typedef xpc_object_t __attribute__((ns_returns_retained)) (*EndpointFromMachPortFunction)(mach_port_t port, uint64_t, uint64_t);
typedef xpc_connection_t __attribute__((ns_returns_retained)) (*ConnectionFromEndpointFunction)(xpc_object_t endpoint);
typedef void (*EnableSimulatorToHostFunction)(xpc_connection_t connection);

static xpc_object_t DTUHIDMessage(const char *messageType, BOOL isBarrier, xpc_object_t payload) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", messageType);
    xpc_dictionary_set_bool(message, "isBarrier", isBarrier);
    xpc_dictionary_set_string(message, "featureIdentifier", DigitizerServiceName.UTF8String);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

static xpc_object_t DigitizerPoint(CGPoint point) {
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(dictionary, "x", point.x);
    xpc_dictionary_set_double(dictionary, "y", point.y);
    return dictionary;
}

/// `IndigoDigitizerEvent` contact phase: start, position or end.
static uint64_t DigitizerEventType(NSEventType eventType) {
    switch (eventType) {
        case NSEventTypeLeftMouseDown:
            return 0;
        case NSEventTypeLeftMouseUp:
            return 2;
        default:
            return 1;
    }
}

/// Sends a barrier and waits for `dtuhidd` to answer it, which also means every earlier message was handled.
static BOOL WaitForDigitizerBarrier(xpc_connection_t connection, dispatch_queue_t queue) {
    // A keyboard event with usage 0 means "no event", so the barrier reaches the daemon without a keypress.
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", 0);
    xpc_dictionary_set_uint64(payload, "state", 2);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL delivered = NO;
    xpc_connection_send_message_with_reply(connection, DTUHIDMessage("IndigoKeyboardButtonEvent", YES, payload), queue,
                                           ^(xpc_object_t reply) {
                                               delivered = xpc_get_type(reply) != XPC_TYPE_ERROR;
                                               dispatch_semaphore_signal(answered);
                                           });
    BOOL timedOut = dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, DigitizerBarrierTimeoutNanoseconds)) != 0;
    return !timedOut && delivered;
}

/// Connects to the simulator's `dtuhidd` digitizer service, or returns nil when no daemon answers.
/// The service lookup succeeds even when `dtuhidd` cannot run, so only an answered barrier proves the path works.
static xpc_connection_t ConnectDigitizerService(id device, dispatch_queue_t queue, void (^connectionDidFail)(void)) {
    EndpointFromMachPortFunction endpointFromMachPort = dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    ConnectionFromEndpointFunction connectionFromEndpoint = dlsym(RTLD_DEFAULT, "xpc_connection_create_from_endpoint");
    EnableSimulatorToHostFunction enableSimulatorToHost = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromMachPort || !connectionFromEndpoint || !enableSimulatorToHost) {
        Log(@"private XPC symbols for simulator services not found");
        return nil;
    }

    NSError *error = nil;
    mach_port_t port = ((mach_port_t(*)(id, SEL, id, NSError **))objc_msgSend)(
        device, NSSelectorFromString(@"lookup:error:"), DigitizerServiceName, &error);
    if (port == MACH_PORT_NULL) {
        Log([NSString stringWithFormat:@"digitizer service lookup failed: %@", error]);
        return nil;
    }
    xpc_object_t endpoint = endpointFromMachPort(port, 0, 0);
    xpc_connection_t connection = endpoint ? connectionFromEndpoint(endpoint) : nil;
    if (!connection) {
        Log(@"cannot create a connection to the digitizer service");
        return nil;
    }
    // Without this the service sees the peer but never a payload.
    enableSimulatorToHost(connection);
    xpc_connection_set_target_queue(connection, queue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            connectionDidFail();
        }
    });
    xpc_connection_resume(connection);

    if (!WaitForDigitizerBarrier(connection, queue)) {
        Log(@"dtuhidd did not answer");
        xpc_connection_cancel(connection);
        return nil;
    }
    usleep(DigitizerActivationDelayMicroseconds);
    return connection;
}


@implementation TouchSender {
    xpc_connection_t _connection;
    dispatch_queue_t _queue;
}

- (instancetype)initWithDevice:(id)device {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("hubtouch.hid", DISPATCH_QUEUE_SERIAL);
        __weak TouchSender *weakSelf = self;
        _connection = ConnectDigitizerService(device, _queue, ^{
            [weakSelf invalidate];
        });
        if (!_connection) {
            return nil;
        }
        _valid = YES;
    }
    return self;
}

- (void)dealloc {
    if (_connection) {
        xpc_connection_cancel(_connection);
    }
}

- (void)invalidate {
    _valid = NO;
}

- (void)sendFingers:(FingerPair)fingers eventType:(NSEventType)eventType {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", DigitizerPoint(fingers.first));
    xpc_dictionary_set_value(payload, "pointTwo", DigitizerPoint(fingers.second));
    xpc_dictionary_set_uint64(payload, "eventType", DigitizerEventType(eventType));
    xpc_dictionary_set_uint64(payload, "edge", 0);
    xpc_dictionary_set_uint64(payload, "target", 0);
    xpc_connection_send_message(_connection, DTUHIDMessage("IndigoDigitizerEvent", NO, payload));
}

- (void)performPath:(GesturePath)path steps:(int)steps {
    [self sendFingers:path(0) eventType:NSEventTypeLeftMouseDown];
    for (int step = 1; step <= steps; step++) {
        usleep(GestureStepIntervalMicroseconds);
        [self sendFingers:path((double)step / steps) eventType:NSEventTypeLeftMouseDragged];
    }
    usleep(GestureStepIntervalMicroseconds);
    [self sendFingers:path(1) eventType:NSEventTypeLeftMouseUp];
    if (!WaitForDigitizerBarrier(_connection, _queue)) {
        Log(@"the simulator did not confirm the gesture");
    }
}

@end

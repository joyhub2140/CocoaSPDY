//
//  SPDYSessionManager.m
//  SPDY
//
//  Copyright (c) 2014 Twitter, Inc. All rights reserved.
//  Licensed under the Apache License v2.0
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Created by Michael Schore and Jeffrey Pinner.
//

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import <SystemConfiguration/SystemConfiguration.h>
#import "SPDYStreamManager.h"
#import <arpa/inet.h>
#import "SPDYCommonLogger.h"
#import "SPDYOrigin.h"
#import "SPDYProtocol.h"
#import "SPDYSession.h"
#import "SPDYSessionManager.h"
#import "SPDYStreamManager.h"
#import "SPDYStream.h"
#import "NSURLRequest+SPDYURLRequest.h"

static NSString *const SPDYSessionManagerKey = @"com.twitter.SPDYSessionManager";
static volatile bool reachabilityIsWWAN;

#if TARGET_OS_IPHONE
static char *const SPDYReachabilityQueue = "com.twitter.SPDYReachabilityQueue";

static SCNetworkReachabilityRef reachabilityRef;
static dispatch_queue_t reachabilityQueue;

static void SPDYReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info);
#endif

@interface SPDYSessionPool : NSObject
- (id)initWithOrigin:(SPDYOrigin *)origin configuration:(SPDYConfiguration *)configuration error:(NSError **)pError;
- (NSUInteger)remove:(SPDYSession *)session;
- (SPDYSession *)next;
@end

@implementation SPDYSessionPool
{
    NSMutableArray *_sessions;
}

- (id)initWithOrigin:(SPDYOrigin *)origin configuration:(SPDYConfiguration *)configuration error:(NSError **)pError
{
    self = [super init];
    if (self) {
        NSUInteger size = configuration.sessionPoolSize;
        _sessions = [[NSMutableArray alloc] initWithCapacity:size];
        for (NSUInteger i = 0; i < size; i++) {
            SPDYSession *session = [[SPDYSession alloc] initWithOrigin:origin
                                                         configuration:configuration
                                                              cellular:reachabilityIsWWAN
                                                                 error:pError];
            if (!session) {
                return nil;
            }
            [_sessions addObject:session];
        }
    }
    return self;
}

- (NSUInteger)remove:(SPDYSession *)session
{
    [_sessions removeObject:session];
    return _sessions.count;
}

- (SPDYSession *)next
{
    SPDYSession *session;

    // TODO: this nil check shouldn't be necessary, is there a threading issue?
    if (_sessions.count == 0) {
        return nil;
    }

    do {
        session = _sessions[0];
    } while (session && !session.isOpen && [self remove:session] > 0);
    if (!session.isOpen) return nil; // No open sessions in the pool

    // Rotate
    if (_sessions.count > 1) {
        [_sessions removeObjectAtIndex:0];
        [_sessions addObject:session];
    }

    return session;
}

@end

@implementation SPDYSessionManager
{
    SPDYOrigin *_origin;
    SPDYSessionPool *_basePool;
    SPDYSessionPool *_wwanPool;
    SPDYStreamManager *_pendingStreams;
}

+ (void)initialize
{
    reachabilityIsWWAN = NO;

#if TARGET_OS_IPHONE
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = (uint8_t)sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    SCNetworkReachabilityContext context = {0, NULL, NULL, NULL, NULL};
    reachabilityRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);

    if (SCNetworkReachabilitySetCallback(reachabilityRef, SPDYReachabilityCallback, &context)) {
        reachabilityQueue = dispatch_queue_create(SPDYReachabilityQueue, DISPATCH_QUEUE_SERIAL);
        SCNetworkReachabilitySetDispatchQueue(reachabilityRef, reachabilityQueue);
    }

    dispatch_async(reachabilityQueue, ^{
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags)) {
            SPDYReachabilityCallback(reachabilityRef, flags, NULL);
        }
    });
#endif
}

+ (SPDYSessionManager *)localManagerForOrigin:(SPDYOrigin *)origin
{
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    NSMutableDictionary *originDictionary = threadDictionary[SPDYSessionManagerKey];
    SPDYSessionManager *manager = originDictionary[origin];
    if (!manager) {
        manager = [[SPDYSessionManager alloc] initWithOrigin:origin];
        threadDictionary[SPDYSessionManagerKey] = manager;
    }
    return manager;
}

- (id)initWithOrigin:(SPDYOrigin *)origin
{
    self = [super init];
    if (self) {
        _origin = origin;
        _pendingStreams = [[SPDYStreamManager alloc] init];
    }
    return self;
}

- (void)queueRequest:(SPDYProtocol *)protocol error:(NSError **)pError
{
    *pError = nil;
    SPDYSession *session;
    SPDYSessionPool * __strong *pool = reachabilityIsWWAN ? &_wwanPool : &_basePool;

    if (*pool) {
        session = [*pool next];
        if (!session && !protocol.request.SPDYDeferrableInterval > 0) {
            *pool = [[SPDYSessionPool alloc] initWithOrigin:_origin
                                              configuration:[SPDYProtocol currentConfiguration]
                                                      error:pError];
            if (*pool) {
                session = [*pool next];
            }
        }
    }

    if (session) {
        [session dispatchRequest:protocol];
    } else {
        SPDYStream *stream = [[SPDYStream alloc] initWithProtocol:protocol];
        [_pendingStreams addStream:stream];
    }
}

- (void)cancelRequest:(SPDYProtocol *)protocol
{
    [_pendingStreams removeStreamForProtocol:protocol];
}

- (void)removeSession:(SPDYSession *)session
{
    SPDY_DEBUG(@"Removing session: %@", session);
    SPDYSessionPool * __strong *pool = session.isCellular ? &_wwanPool : &_basePool;
    if (*pool && [*pool remove:session] == 0) {
        *pool = nil;
    }
}

@end

#if TARGET_OS_IPHONE
static void SPDYReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info)
{
    // Only update if the network is actually reachable
    if (flags & kSCNetworkReachabilityFlagsReachable) {
        reachabilityIsWWAN = (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;
        SPDY_DEBUG(@"reachability updated: %@", reachabilityIsWWAN ? @"WWAN" : @"WLAN");
    }
}
#endif

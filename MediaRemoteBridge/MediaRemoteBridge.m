// MediaRemoteBridge
//
// Since macOS 15.4, only Apple-signed processes may use the private
// MediaRemote framework. /usr/bin/perl is one, so Xotch starts
//
//     /usr/bin/perl mediaremote-bridge.pl MediaRemoteBridge.dylib
//
// and perl loads this library and calls XotchMediaRemoteRun (see the .pl).
// Same technique as github.com/ungive/mediaremote-adapter (BSD-3), written
// from scratch for Xotch.
//
// Protocol (one line per message):
//   stdout: JSON object describing the current media; "artwork" (base64) is
//           only included when the artwork changed.
//   stdin:  play | pause | toggle | next | previous | seek <seconds> | refresh
// The bridge exits when stdin closes, so it never outlives Xotch.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (^XotchInfoBlock)(CFDictionaryRef info);
typedef void (^XotchBoolBlock)(Boolean value);
typedef void (^XotchClientBlock)(id client);

static void (*MRGetNowPlayingInfo)(dispatch_queue_t, XotchInfoBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, XotchBoolBlock);
static void (*MRGetClient)(dispatch_queue_t, XotchClientBlock);
static void (*MRRegisterForNotifications)(dispatch_queue_t);
static Boolean (*MRSendCommand)(int command, CFDictionaryRef options);
static void (*MRSetElapsedTime)(double seconds);
static CFStringRef (*MRClientGetBundleID)(id client);
static CFStringRef (*MRClientGetParentBundleID)(id client);

enum { kPlay = 0, kPause = 1, kToggle = 2, kNext = 4, kPrevious = 5 };

static NSUInteger lastArtworkHash = 0;
static BOOL emitScheduled = NO;

static void writeLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id jsonSafe(id value) {
    return value ?: [NSNull null];
}

static void emitNow(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    MRGetNowPlayingInfo(queue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        MRGetIsPlaying(queue, ^(Boolean playing) {
            MRGetClient(queue, ^(id client) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                NSString *bundleID = nil;
                if (client) {
                    if (MRClientGetParentBundleID) {
                        bundleID = (__bridge NSString *)MRClientGetParentBundleID(client);
                    }
                    if (!bundleID && MRClientGetBundleID) {
                        bundleID = (__bridge NSString *)MRClientGetBundleID(client);
                    }
                }
                out[@"bundleID"] = jsonSafe(bundleID);
                out[@"title"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                out[@"artist"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                out[@"elapsed"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                out[@"rate"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([timestamp isKindOfClass:[NSDate class]]) {
                    out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
                }
                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSUInteger artworkHash = [artwork isKindOfClass:[NSData class]] ? artwork.hash ^ artwork.length : 0;
                if (artworkHash != lastArtworkHash) {
                    lastArtworkHash = artworkHash;
                    out[@"artwork"] = artworkHash ? [artwork base64EncodedStringWithOptions:0] : @"";
                }
                writeLine(out);
            });
        });
    });
}

// MediaRemote posts bursts of notifications; coalesce them.
static void scheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        emitScheduled = NO;
        emitNow();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    if ([command isEqualToString:@"play"]) MRSendCommand(kPlay, NULL);
    else if ([command isEqualToString:@"pause"]) MRSendCommand(kPause, NULL);
    else if ([command isEqualToString:@"toggle"]) MRSendCommand(kToggle, NULL);
    else if ([command isEqualToString:@"next"]) MRSendCommand(kNext, NULL);
    else if ([command isEqualToString:@"previous"]) MRSendCommand(kPrevious, NULL);
    else if ([command isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsedTime) {
        MRSetElapsedTime(parts[1].doubleValue);
    }
    scheduleEmit();
}

static BOOL loadSymbols(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) return NO;
    MRGetNowPlayingInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient = dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    MRRegisterForNotifications = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSendCommand = dlsym(handle, "MRMediaRemoteSendCommand");
    MRSetElapsedTime = dlsym(handle, "MRMediaRemoteSetElapsedTime");
    MRClientGetBundleID = dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
    MRClientGetParentBundleID = dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
    return MRGetNowPlayingInfo && MRGetIsPlaying && MRGetClient && MRRegisterForNotifications && MRSendCommand;
}

// Called by perl as an XSUB; the two arguments are perl's and are ignored.
void XotchMediaRemoteRun(void *perlInterpreter, void *perlCV) {
    (void)perlInterpreter;
    (void)perlCV;
    @autoreleasepool {
        if (!loadSymbols()) {
            writeLine(@{ @"error": @"MediaRemote is unavailable" });
            exit(1);
        }

        MRRegisterForNotifications(dispatch_get_main_queue());
        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                (void)note;
                scheduleEmit();
            }];
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char buffer[256];
            while (fgets(buffer, sizeof buffer, stdin)) {
                NSString *line = [[NSString stringWithUTF8String:buffer]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([line isEqualToString:@"refresh"]) {
                        lastArtworkHash = 0;
                        scheduleEmit();
                    } else {
                        handleCommand(line);
                    }
                });
            }
            exit(0);
        });

        emitNow();
    }
    dispatch_main();
}

// Long-running Find My watcher. Keeps one FMFSession alive and exposes the
// newest known friend locations on localhost for locationspoofd.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

static const int kWatchPort = 8766;
static const NSTimeInterval kRefreshDeadline = 40.0;
static const NSTimeInterval kSingleRefreshCacheWindow = 30.0;
static const NSTimeInterval kBulkRefreshCacheWindow = 60.0;
static const NSTimeInterval kRunLoopStep = 0.2;
// FMF drops coordinates off cached fixes as they age; auto-refresh when a
// /friends read sees anything older than this (or with no fix at all).
static const NSTimeInterval kAutoRefreshAge = 10 * 60;
static const NSTimeInterval kAutoRefreshMinInterval = 5 * 60;
static const NSTimeInterval kAutoRefreshTick = 5 * 60;

@interface FMFLocation : NSObject
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, strong) NSDate *timestamp;
@property(nonatomic, readonly) BOOL isValid;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSString *shortAddress;
@property(nonatomic, copy) NSString *longAddress;
@property(nonatomic, strong) id handle;
@end

@interface FMFHandle : NSObject
+ (instancetype)handleWithId:(NSString *)i;
- (NSString *)identifier;
@end

@interface FMFSession : NSObject
- (instancetype)initWithDelegate:(id)d delegateQueue:(id)q;
- (void)reloadDataIfNotLoaded;
- (void)forceRefresh;
- (void)setHandles:(id)handles;
- (void)locationForHandle:(id)h completion:(void (^)(FMFLocation *))c;
- (void)refreshLocationForHandle:(id)h callerId:(id)callerId priority:(long long)priority completion:(id)completion;
- (void)refreshLocationForHandles:(id)handles callerId:(id)callerId priority:(long long)priority completion:(id)completion;
- (void)getHandlesSharingLocationsWithMeWithGroupId:(id)g completion:(void (^)(NSArray *))c;
@end

static NSMutableDictionary<NSString *, FMFLocation *> *gLatest;
static NSMutableDictionary<NSString *, FMFHandle *> *gHandlesById;
static NSMutableSet<NSString *> *gKnownIds;
// Handles that have produced at least one usable fix. Distinguishes "shares
// with me but is offline right now" from "never shares with me at all" --
// FMF lists both, and only the former is worth waiting on or refreshing for.
static NSMutableSet<NSString *> *gEverLocated;
static NSMutableSet<NSString *> *gRefreshExpected;
static NSMutableSet<NSString *> *gRefreshLogged;
static NSObject *gLock;
static FMFSession *gSession;
static Class gHandleCls;
static BOOL gHandlesLoaded;
static BOOL gRefreshInProgress;
static NSUInteger gRefreshGeneration;
static NSString *gRefreshKey;
static NSTimeInterval gRefreshStart;
static NSTimeInterval gLastAutoRefresh;
static NSTimeInterval gRefreshCacheWindow;
// Consecutive bulk refreshes that came back with nothing at all. An FMFSession
// held open for days rots: fmfd still accepts locate requests and still answers
// cached reads, but stops actually locating, so fixes only land while the Find
// My app is driving its own session. FMFCore exposes no way to revive it and a
// fresh process works immediately, so we bail and let the plist's KeepAlive
// respawn us with a new session.
// ponytail: restart-on-stall beats reimplementing session recovery; revisit if
// a real reconnect selector ever turns up in FMFCore.
static NSUInteger gDeadRefreshStreak;
static const NSUInteger kDeadRefreshStreakLimit = 3;

static IMP gOrigFMFSessionDidUpdateLocations;
static dispatch_source_t gHTTPSource;
static dispatch_source_t gAutoRefreshSource;
static BOOL gHandleReloadScheduled;
static int gListenFD = -1;

static void LoadHandles(void);
static void ScheduleLoadHandles(NSString *reason);
static NSDictionary *Refresh(NSString *handle, NSString *callerId, long long priority);

static void Log(NSString *line) {
    fprintf(stderr, "%s\n", line.UTF8String);
}

static BOOL IsRecentRefreshLocation(FMFLocation *loc) {
    return gRefreshStart > 0 &&
        loc.timestamp.timeIntervalSince1970 >= gRefreshStart - gRefreshCacheWindow;
}

static BOOL IsKnownLocation(FMFLocation *loc) {
    return loc && loc.isValid &&
        CLLocationCoordinate2DIsValid(loc.coordinate) &&
        !(loc.coordinate.latitude == 0 && loc.coordinate.longitude == 0);
}

// FMF lists people you share *to* alongside people who share *with* you, and a
// one-way friend never produces a fix. "Has it ever located?" is the only
// signal that separates them from a real friend who is merely offline right
// now. Before anything has located we know nothing, so assume everyone is
// locatable and let the first refresh bootstrap the answer.
// Caller must hold gLock.
static BOOL CanBeLocated(NSString *hid) {
    return gEverLocated.count == 0 || [gEverLocated containsObject:hid];
}

static void StoreLocation(FMFLocation *loc) {
    if (![loc isKindOfClass:objc_getClass("FMFLocation")]) return;
    NSString *hid = [loc.handle respondsToSelector:@selector(identifier)] ? [loc.handle identifier] : nil;
    if (!hid.length) return;
    @synchronized (gLock) {
        FMFLocation *prev = gLatest[hid];
        if (!prev || loc.timestamp.timeIntervalSince1970 >= prev.timestamp.timeIntervalSince1970) {
            gLatest[hid] = loc;
        }
        if (IsKnownLocation(loc)) [gEverLocated addObject:hid];
    }
}

static void StoreLocations(id locations) {
    if (!locations) return;
    if ([locations isKindOfClass:objc_getClass("FMFLocation")]) {
        StoreLocation(locations);
        return;
    }
    if (![locations respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return;
    for (id loc in locations) StoreLocation(loc);
}

@interface FMFWatchDelegate : NSObject
@end
@implementation FMFWatchDelegate
- (void)didReceiveLocation:(FMFLocation *)loc { StoreLocation(loc); }
- (void)didUpdateLocation:(FMFLocation *)loc { StoreLocation(loc); }
- (void)didUpdateLocations:(id)locations { StoreLocations(locations); }
- (void)modelDidLoad { ScheduleLoadHandles(@"modelDidLoad"); }
- (void)didUpdateFollowing:(id)following { ScheduleLoadHandles(@"didUpdateFollowing"); }
- (void)didStartFollowingHandle:(id)handle { ScheduleLoadHandles(@"didStartFollowingHandle"); }
- (void)didStopFollowingHandle:(id)handle { ScheduleLoadHandles(@"didStopFollowingHandle"); }
- (void)didStartAbilityToGetLocationForHandle:(id)handle { ScheduleLoadHandles(@"didStartAbilityToGetLocationForHandle"); }
- (void)didStopAbilityToGetLocationForHandle:(id)handle { ScheduleLoadHandles(@"didStopAbilityToGetLocationForHandle"); }
// Swallow every other delegate selector fmfd sends.
- (void)forwardInvocation:(NSInvocation *)inv {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [NSMethodSignature signatureWithObjCTypes:"v@:@@@@"]; }
- (BOOL)respondsToSelector:(SEL)s { return YES; }
@end

static void InstallFMFSessionLocationHook(Class sessionClass) {
    SEL sel = @selector(didUpdateLocations:);
    Method m = class_getInstanceMethod(sessionClass, sel);
    if (!m) {
        Log(@"FMFSession didUpdateLocations: not found");
        return;
    }
    gOrigFMFSessionDidUpdateLocations = method_getImplementation(m);
    IMP replacement = imp_implementationWithBlock(^void(id obj, id locations) {
        StoreLocations(locations);
        ((void (*)(id, SEL, id))gOrigFMFSessionDidUpdateLocations)(obj, sel, locations);
    });
    method_setImplementation(m, replacement);
}

static void LoadHandles(void) {
    [gSession getHandlesSharingLocationsWithMeWithGroupId:nil completion:^(NSArray *ids) {
        NSArray *idArray = [ids respondsToSelector:@selector(allObjects)] ? [(id)ids allObjects] : ids;
        NSMutableArray *handles = [NSMutableArray array];
        NSMutableSet<NSString *> *loadedIds = [NSMutableSet set];
        NSMutableDictionary<NSString *, FMFHandle *> *loadedById = [NSMutableDictionary dictionary];
        for (id x in idArray) {
            NSString *identifier = [x isKindOfClass:NSString.class] ? x : [x description];
            if (!identifier.length) continue;
            FMFHandle *h = [gHandleCls handleWithId:identifier];
            if (!h) continue;
            [handles addObject:h];
            [loadedIds addObject:identifier];
            loadedById[identifier] = h;
        }
        // Swap in whole, not clear-then-fill: this now runs on a timer, and the
        // old in-place rebuild left a window where /friends read an empty set.
        BOOL discovered;
        @synchronized (gLock) {
            discovered = gHandlesLoaded && ![loadedIds isSubsetOfSet:gKnownIds];
            gKnownIds = loadedIds;
            gHandlesById = loadedById;
            gHandlesLoaded = YES;
        }
        [gSession setHandles:[NSSet setWithArray:handles]];
        for (FMFHandle *h in handles) {
            [gSession locationForHandle:h completion:^(FMFLocation *loc) { StoreLocation(loc); }];
        }
        Log([NSString stringWithFormat:@"watch handles loaded: %lu", (unsigned long)handles.count]);
        // A brand-new sharer is not in gEverLocated, so MaybeAutoRefresh will
        // never consider them stale and they would sit at valid:false until an
        // unrelated friend went stale. One bulk locate bootstraps them; if it
        // yields nothing they are correctly treated as one-way from then on.
        if (discovered) {
            Log(@"watch new handle appeared, locating");
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                Refresh(nil, nil, 1);
            });
        }
    }];
}

static void ScheduleLoadHandles(NSString *reason) {
    @synchronized (gLock) {
        if (gHandleReloadScheduled) return;
        gHandleReloadScheduled = YES;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (gLock) { gHandleReloadScheduled = NO; }
        Log([NSString stringWithFormat:@"watch reloading handles: %@", reason ?: @"callback"]);
        LoadHandles();
    });
}

static BOOL CoverageComplete(void) {
    @synchronized (gLock) {
        if (gRefreshExpected.count == 0) return YES;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        BOOL complete = YES;
        for (NSString *hid in gRefreshExpected) {
            FMFLocation *loc = gLatest[hid];
            if (!loc || !IsRecentRefreshLocation(loc)) {
                complete = NO;
                continue;
            }
            if (![gRefreshLogged containsObject:hid]) {
                [gRefreshLogged addObject:hid];
                Log([NSString stringWithFormat:@"watch refresh fresh handle=%@ elapsed=%.1fs age=%.1fs timestamp=%lld",
                    hid, now - gRefreshStart, now - loc.timestamp.timeIntervalSince1970,
                    (long long)loc.timestamp.timeIntervalSince1970]);
            }
        }
        return complete;
    }
}

static NSString *RefreshKey(NSString *handle) {
    return handle.length ? handle : @"*";
}

static NSArray<NSString *> *AllIdsSnapshot(void) {
    @synchronized (gLock) {
        return [[gKnownIds allObjects] copy];
    }
}

static NSArray<FMFHandle *> *HandlesForIds(NSArray<NSString *> *ids) {
    NSMutableArray *handles = [NSMutableArray array];
    @synchronized (gLock) {
        for (NSString *hid in ids) {
            FMFHandle *h = gHandlesById[hid];
            if (h) [handles addObject:h];
        }
    }
    return handles;
}

static void RequestRefresh(NSString *handle, NSArray<FMFHandle *> *handles, NSString *callerId, long long priority) {
    id completion = ^{};

    if (handle.length && handles.count == 1 &&
        [gSession respondsToSelector:@selector(refreshLocationForHandle:callerId:priority:completion:)]) {
        Log([NSString stringWithFormat:@"watch refreshLocationForHandle handle=%@ callerId=%@ priority=%lld",
            handle, callerId ?: @"<nil>", priority]);
        [gSession refreshLocationForHandle:handles[0] callerId:callerId priority:priority completion:completion];
        return;
    }

    if (!handle.length && handles.count > 0 &&
        [gSession respondsToSelector:@selector(refreshLocationForHandle:callerId:priority:completion:)]) {
        Log([NSString stringWithFormat:@"watch refreshLocationForHandle bulk count=%lu callerId=%@ priority=%lld",
            (unsigned long)handles.count, callerId ?: @"<nil>", priority]);
        for (FMFHandle *h in handles) {
            [gSession refreshLocationForHandle:h callerId:callerId priority:priority completion:completion];
        }
        return;
    }

    if (!handle.length &&
        [gSession respondsToSelector:@selector(refreshLocationForHandles:callerId:priority:completion:)]) {
        Log([NSString stringWithFormat:@"watch refreshLocationForHandles fallback count=%lu callerId=%@ priority=%lld",
            (unsigned long)handles.count, callerId ?: @"<nil>", priority]);
        [gSession refreshLocationForHandles:[NSSet setWithArray:handles] callerId:callerId priority:priority completion:completion];
        return;
    }

    Log(@"watch refresh fallback forceRefresh");
    [gSession forceRefresh];
}

static NSDictionary *Refresh(NSString *handle, NSString *callerId, long long priority) {
    NSString *key = RefreshKey(handle);
    NSUInteger generation;
    @synchronized (gLock) {
        if (gRefreshInProgress && [gRefreshKey isEqualToString:key]) {
            return @{@"ok": @NO, @"message": @"friends refresh already in progress", @"handle": handle ?: @""};
        }
        // A different handle supersedes the old wait. FMF does not expose a
        // cancel primitive here; advancing the generation lets the old request
        // stop waiting and lets this one own the current forceRefresh cycle.
        gRefreshGeneration++;
        generation = gRefreshGeneration;
        gRefreshInProgress = YES;
        gRefreshKey = [key copy];
    }

    @try {
        NSArray<NSString *> *ids = handle.length ? @[handle] : AllIdsSnapshot();
        NSArray<FMFHandle *> *handles = HandlesForIds(ids);
        if (ids.count == 0 || handles.count == 0) {
            return @{@"ok": @NO, @"message": handle.length ? @"friend handle not found" : @"no friend handles loaded"};
        }

        @synchronized (gLock) {
            NSMutableSet *expected = [NSMutableSet setWithArray:ids];
            if (!handle.length) {
                for (NSString *hid in ids) {
                    // Only drop handles that have *never* located. Dropping on
                    // "no valid fix right now" made a stale set collapse to
                    // empty, so coverage completed instantly and every refresh
                    // reported success without waiting for anything.
                    if (!CanBeLocated(hid)) {
                        [expected removeObject:hid];
                        Log([NSString stringWithFormat:@"watch refresh skipping never-located handle=%@", hid]);
                    }
                }
            }
            gRefreshExpected = expected;
            [gRefreshLogged removeAllObjects];
            gRefreshCacheWindow = handle.length ? kSingleRefreshCacheWindow : kBulkRefreshCacheWindow;
            gRefreshStart = [NSDate date].timeIntervalSince1970;
        }

        RequestRefresh(handle, handles, callerId, priority);

        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:kRefreshDeadline];
        while ([end timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kRunLoopStep]];
            @synchronized (gLock) {
                if (generation != gRefreshGeneration) {
                    return @{@"ok": @NO, @"message": @"friends refresh superseded", @"handle": handle ?: @""};
                }
            }
            if (CoverageComplete()) break;
        }

        // A refresh that produced nothing used to be indistinguishable from a
        // good one: this returned ok:YES either way, so fmfd silently ignoring
        // our locate requests looked like success while /friends served fixes
        // that only ever arrived when the Find My app was opened. Say so.
        NSUInteger expectedCount, freshCount, streak = 0;
        BOOL healthSignal;
        @synchronized (gLock) {
            expectedCount = gRefreshExpected.count;
            freshCount = gRefreshLogged.count;
            // Only a bulk refresh is a usable health signal -- a single-handle
            // miss just means that one friend's device is off or offline.
            healthSignal = (!handle.length && expectedCount >= 2);
            if (healthSignal) {
                gDeadRefreshStreak = (freshCount == 0) ? gDeadRefreshStreak + 1 : 0;
                streak = gDeadRefreshStreak;
            }
        }
        if (expectedCount > 0) {
            Log([NSString stringWithFormat:@"watch refresh coverage %lu/%lu key=%@",
                (unsigned long)freshCount, (unsigned long)expectedCount, key]);
        }
        if (healthSignal && freshCount == 0) {
            Log([NSString stringWithFormat:
                @"watch refresh produced no fixes (streak %lu/%lu): fmfd accepted the locate but delivered nothing",
                (unsigned long)streak, (unsigned long)kDeadRefreshStreakLimit]);
            if (streak >= kDeadRefreshStreakLimit) {
                Log(@"watch FMFSession looks dead, exiting so launchd respawns with a fresh one");
                exit(0);
            }
        }

        // Still ok:YES even with no fixes -- callers want the cached rows, and
        // the log above is what distinguishes the two cases.
        return @{@"ok": @YES};
    } @finally {
        @synchronized (gLock) {
            if (generation == gRefreshGeneration) {
                [gRefreshExpected removeAllObjects];
                [gRefreshLogged removeAllObjects];
                gRefreshStart = 0;
                gRefreshInProgress = NO;
                gRefreshKey = nil;
            }
        }
    }
}

// FMF leaves shortAddress/longAddress nil for some friends even on valid
// fixes, so we reverse-geocode those coords ourselves and cache the result
// per handle. Async: the address shows up on the next /friends read.
// ponytail: one CLGeocoder shared, throttled requests just retry next read.
static NSMutableDictionary<NSString *, NSDictionary *> *gGeocode;
static NSMutableSet<NSString *> *gGeocoding;

static void MaybeGeocode(NSString *hid, CLLocationCoordinate2D c) {
    @synchronized (gLock) {
        NSDictionary *g = gGeocode[hid];
        if (g && fabs([g[@"lat"] doubleValue] - c.latitude) < 5e-4 &&
                 fabs([g[@"lon"] doubleValue] - c.longitude) < 5e-4) return;
        // CLGeocoder rate-limits and cancels overlapping requests, so keep
        // just one in flight; remaining handles fill over successive reads.
        if (gGeocoding.count) return;
        [gGeocoding addObject:hid];
    }
    static CLGeocoder *geo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ geo = [CLGeocoder new]; });
    CLLocation *l = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    [geo reverseGeocodeLocation:l completionHandler:^(NSArray<CLPlacemark *> *pms, NSError *err) {
        CLPlacemark *p = pms.firstObject;
        NSString *shortA = nil, *longA = nil;
        if (p) {
            NSMutableArray *loc2 = [NSMutableArray array];
            if (p.locality.length) [loc2 addObject:p.locality];
            if (p.administrativeArea.length) [loc2 addObject:p.administrativeArea];
            shortA = p.name.length && ![p.name isEqualToString:p.thoroughfare] &&
                     [p.name rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location == NSNotFound
                     ? p.name : [loc2 componentsJoinedByString:@", "];
            NSMutableArray *lines = [NSMutableArray array];
            NSString *street = [[@[p.subThoroughfare ?: @"", p.thoroughfare ?: @""]
                componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (street.length) [lines addObject:street];
            NSString *city = [loc2 componentsJoinedByString:@", "];
            if (p.postalCode.length) city = [city stringByAppendingFormat:@"  %@", p.postalCode];
            if (city.length) [lines addObject:city];
            if (p.country.length) [lines addObject:p.country];
            longA = [lines componentsJoinedByString:@"\n"];
        }
        @synchronized (gLock) {
            [gGeocoding removeObject:hid];
            if (shortA.length || longA.length) {
                gGeocode[hid] = @{@"lat": @(c.latitude), @"lon": @(c.longitude),
                                  @"short": shortA ?: @"", @"long": longA ?: @""};
            }
        }
    }];
}

static NSDictionary *FriendRow(NSString *hid, FMFLocation *loc, NSDictionary *geocode) {
    BOOL known = IsKnownLocation(loc);
    NSString *shortA = loc.shortAddress.length ? loc.shortAddress : nil;
    NSString *longA = loc.longAddress.length ? loc.longAddress : nil;
    if (known && (!shortA || !longA)) {
        NSDictionary *g = geocode[hid];
        if (g) {
            if (!shortA && [g[@"short"] length]) shortA = g[@"short"];
            if (!longA && [g[@"long"] length]) longA = g[@"long"];
        }
        if (!shortA || !longA) MaybeGeocode(hid, loc.coordinate);
    }
    return @{
        @"handle": hid ?: @"",
        @"lat": known ? @(loc.coordinate.latitude) : [NSNull null],
        @"lon": known ? @(loc.coordinate.longitude) : [NSNull null],
        @"accuracy": known ? @(loc.horizontalAccuracy) : [NSNull null],
        @"address": shortA ?: [NSNull null],
        @"fullAddress": longA ?: [NSNull null],
        @"timestamp": loc.timestamp ? @((long long)loc.timestamp.timeIntervalSince1970) : [NSNull null],
        @"valid": @(known),
    };
}

static NSString *FriendsJSON(NSString *handle) {
    NSMutableArray *friends = [NSMutableArray array];
    BOOL loaded;
    NSArray *ids;
    NSDictionary *locations;
    NSDictionary *geocode;
    @synchronized (gLock) {
        loaded = gHandlesLoaded;
        ids = handle.length ? @[handle] : [[gKnownIds allObjects] sortedArrayUsingSelector:@selector(compare:)];
        if (handle.length && ![gKnownIds containsObject:handle]) ids = @[];
        locations = [gLatest copy];
        geocode = [gGeocode copy];
    }
    for (NSString *hid in ids) {
        [friends addObject:FriendRow(hid, locations[hid], geocode)];
    }
    NSDictionary *obj = @{@"ok": @YES, @"loaded": @(loaded), @"friends": friends};
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"ok\":false,\"message\":\"json encode failed\"}";
}

// Kicks off a background bulk refresh (non-blocking) if any known friend's
// fix is missing or older than kAutoRefreshAge, rate-limited so reads don't
// pile refreshes on top of each other.
static void MaybeAutoRefresh(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    @synchronized (gLock) {
        if (!gHandlesLoaded || gKnownIds.count == 0) return;
        if (gRefreshInProgress) return;
        if (now - gLastAutoRefresh < kAutoRefreshMinInterval) return;
        BOOL stale = NO;
        for (NSString *hid in gKnownIds) {
            // A one-way friend can never satisfy this check, so counting them
            // pinned `stale` to YES forever and put us in a permanent bulk
            // locate every kAutoRefreshMinInterval, around the clock.
            if (!CanBeLocated(hid)) continue;
            FMFLocation *loc = gLatest[hid];
            if (!IsKnownLocation(loc) ||
                now - loc.timestamp.timeIntervalSince1970 > kAutoRefreshAge) {
                stale = YES;
                break;
            }
        }
        if (!stale) return;
        gLastAutoRefresh = now;
    }
    Log(@"watch auto-refresh: locations stale");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Refresh(nil, nil, 1);
    });
}

// Keeps fixes warm on its own so opening the app shows fresh locations
// without a blocking refresh. MaybeAutoRefresh no-ops when nothing is stale.
static void StartAutoRefreshTimer(void) {
    gAutoRefreshSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gAutoRefreshSource,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
        (uint64_t)(kAutoRefreshTick * NSEC_PER_SEC), (uint64_t)(30 * NSEC_PER_SEC));
    // Reload the handle list here too: the FMF delegate callbacks that are
    // supposed to announce a new sharer may never fire, and a silently
    // swallowed selector is indistinguishable from one that does not exist.
    dispatch_source_set_event_handler(gAutoRefreshSource, ^{ LoadHandles(); MaybeAutoRefresh(); });
    dispatch_resume(gAutoRefreshSource);
}

static NSString *URLDecode(NSString *s) {
    return [s stringByRemovingPercentEncoding] ?: s;
}

static NSDictionary<NSString *, NSString *> *ParseQuery(NSString *query) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        NSString *k = URLDecode(kv.count > 0 ? kv[0] : @"");
        NSString *v = URLDecode(kv.count > 1 ? kv[1] : @"");
        if (k.length) out[k] = v ?: @"";
    }
    return out;
}

static void WriteHTTP(int fd, int status, NSString *body) {
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    const char *statusText = status == 200 ? "OK" : (status == 409 ? "Conflict" : "Error");
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\nConnection: close\r\n\r\n",
        status, statusText, (size_t)data.length);
    (void)write(fd, hdr, (size_t)n);
    (void)write(fd, data.bytes, data.length);
}

static void HandleClient(int cfd) {
    char buf[4096];
    ssize_t n = read(cfd, buf, sizeof(buf) - 1);
    if (n <= 0) { close(cfd); return; }
    buf[n] = 0;

    char method[8] = {0};
    char target[2048] = {0};
    if (sscanf(buf, "%7s %2047s", method, target) != 2 || strcmp(method, "GET") != 0) {
        WriteHTTP(cfd, 400, @"{\"ok\":false,\"message\":\"bad request\"}");
        close(cfd);
        return;
    }

    NSString *t = [NSString stringWithUTF8String:target] ?: @"";
    NSString *path = t;
    NSString *query = @"";
    NSRange qmark = [t rangeOfString:@"?"];
    if (qmark.location != NSNotFound) {
        path = [t substringToIndex:qmark.location];
        query = [t substringFromIndex:qmark.location + 1];
    }
    NSDictionary *q = ParseQuery(query);

    if ([path isEqualToString:@"/friends"]) {
        WriteHTTP(cfd, 200, FriendsJSON(q[@"handle"]));
    } else if ([path isEqualToString:@"/refresh"]) {
        // Best observed targeted-refresh behavior: omitted callerId -> nil,
        // priority 1. Keep query overrides for on-device experiments.
        NSString *callerId = q[@"callerId"];
        NSString *priorityString = q[@"priority"];
        long long priority = priorityString.length ? priorityString.longLongValue : 1;
        NSDictionary *refresh = Refresh(q[@"handle"], callerId, priority);
        BOOL ok = [refresh[@"ok"] boolValue];
        if (ok) {
            WriteHTTP(cfd, 200, FriendsJSON(q[@"handle"]));
        } else {
            NSData *data = [NSJSONSerialization dataWithJSONObject:refresh options:0 error:nil];
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"ok\":false}";
            BOOL conflict = [refresh[@"message"] isEqualToString:@"friends refresh already in progress"];
            WriteHTTP(cfd, conflict ? 409 : 200, body);
        }
    } else {
        WriteHTTP(cfd, 404, @"{\"ok\":false,\"message\":\"not found\"}");
    }
    close(cfd);
}

static void StartHTTPServer(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        Log(@"watch socket failed");
        return;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)kWatchPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        Log(@"watch bind/listen failed");
        close(fd);
        return;
    }

    gListenFD = fd;
    gHTTPSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(gHTTPSource, ^{
        int cfd = accept(gListenFD, NULL, NULL);
        if (cfd < 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ HandleClient(cfd); });
    });
    dispatch_resume(gHTTPSource);
    Log([NSString stringWithFormat:@"fmfwatchd listening on 127.0.0.1:%d", kWatchPort]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        gLatest = [NSMutableDictionary dictionary];
        gGeocode = [NSMutableDictionary dictionary];
        gGeocoding = [NSMutableSet set];
        gHandlesById = [NSMutableDictionary dictionary];
        gKnownIds = [NSMutableSet set];
        gEverLocated = [NSMutableSet set];
        gRefreshExpected = [NSMutableSet set];
        gRefreshLogged = [NSMutableSet set];
        gLock = [NSObject new];
        gRefreshCacheWindow = kBulkRefreshCacheWindow;

        if (!dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW)) {
            Log(@"FMFCore unavailable");
            return 1;
        }

        gHandleCls = objc_getClass("FMFHandle");
        Class sessionCls = objc_getClass("FMFSession");
        InstallFMFSessionLocationHook(sessionCls);

        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        gSession = [[sessionCls alloc] initWithDelegate:[FMFWatchDelegate new] delegateQueue:delegateQueue];
        [gSession reloadDataIfNotLoaded];
        LoadHandles();
        StartHTTPServer();
        StartAutoRefreshTimer();

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}

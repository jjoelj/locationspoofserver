// Long-running Find My watcher. Lists friends and triggers locates through its
// own session, and serves the newest friend locations on localhost for
// locationspoofd. The locations themselves arrive from the LSSFindMy tweak in
// Messages (POST /ingest), on every iOS version: iOS 17+ SIGKILLs a standalone
// daemon that receives a decrypted friend location, and Messages may.
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
#include <sys/stat.h>
#include <notify.h>
#include <signal.h>
#include <sys/sysctl.h>

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
static const NSTimeInterval kShareDeadline = 20.0;

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
- (void)getHandlesFollowingMyLocationWithGroupId:(id)g completion:(void (^)(NSArray *))c;
- (void)sendFriendshipOfferToHandle:(id)h groupId:(id)g callerId:(id)c endDate:(NSDate *)e completion:(id)completion;
- (void)stopSharingMyLocationWithHandle:(id)h groupId:(id)g callerId:(id)c completion:(id)completion;
@end

// iOS 17+ moved friends to FindMyLocate (findmylocated); FMFSession still
// loads there but lists nobody. Same split BlueBubbles makes for macOS 14+.
@interface FMLHandle : NSObject
+ (instancetype)handleWithIdentifier:(NSString *)i;
- (NSString *)identifier;
@end

@interface FindMyLocateSession : NSObject
- (void)startUpdatingFriendsWithInitialUpdates:(BOOL)initial completion:(id)c;
- (void)getFriendsSharingLocationsWithMeWithCompletion:(void (^)(id friends))c;
- (void)getFriendsFollowingMyLocationWithCompletion:(void (^)(id friends))c;
- (void)startRefreshingLocationForHandles:(id)handles priority:(long long)p isFromGroup:(BOOL)g
                           reverseGeocode:(BOOL)geo completion:(id)c;
- (void)stopSharingLocationWith:(id)h isFromGroup:(BOOL)g completion:(id)c;
- (void)setFriendshipUpdateCallback:(id)c;
@end

// A fix from Messages (via /ingest) in FMFLocation's shape, so everything
// downstream of gLatest stays as it was.
@interface LSSFix : NSObject
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, strong) NSDate *timestamp;
@property(nonatomic) BOOL isValid;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSString *shortAddress;
@property(nonatomic, copy) NSString *longAddress;
@end
@implementation LSSFix
@end

static BOOL gFML;
static FindMyLocateSession *gFMLSession;

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
// Restart-on-stall beats reimplementing session recovery; revisit if
// a real reconnect selector ever turns up in FMFCore.
static NSUInteger gDeadRefreshStreak;
static const NSUInteger kDeadRefreshStreakLimit = 3;

static NSTimeInterval gLastIngest;
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

// launchd appends our stderr to /var/log/fmfwatchd.log forever; empty it
// past 1MB. lseek too, in case launchd did not open it O_APPEND.
static void TrimLog(void) {
    struct stat st;
    if (fstat(STDERR_FILENO, &st) == 0 && st.st_size > (1 << 20)) {
        ftruncate(STDERR_FILENO, 0);
        lseek(STDERR_FILENO, 0, SEEK_SET);
    }
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

static void StoreFix(NSString *hid, FMFLocation *loc) {
    if (!hid.length || !loc) return;
    @synchronized (gLock) {
        FMFLocation *prev = gLatest[hid];
        if (!prev || loc.timestamp.timeIntervalSince1970 >= prev.timestamp.timeIntervalSince1970) {
            gLatest[hid] = loc;
        }
        if (IsKnownLocation(loc)) [gEverLocated addObject:hid];
    }
}

// Rows from the LSSFindMy tweak: a JSON array of {h, lat, lon, acc, ts, sa?,
// la?}, ts in seconds since 1970. An empty array is the tweak's "I'm awake".
static NSUInteger Ingest(NSData *body) {
    NSArray *rows = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![rows isKindOfClass:NSArray.class]) return 0;
    NSUInteger stored = 0;
    for (NSDictionary *r in rows) {
        if (![r isKindOfClass:NSDictionary.class]) continue;
        NSString *hid = r[@"h"];
        double ts = [r[@"ts"] doubleValue];
        if (![hid isKindOfClass:NSString.class] || !hid.length || ts <= 0) continue;
        LSSFix *f = [LSSFix new];
        f.coordinate = CLLocationCoordinate2DMake([r[@"lat"] doubleValue], [r[@"lon"] doubleValue]);
        f.horizontalAccuracy = [r[@"acc"] doubleValue];
        f.timestamp = [NSDate dateWithTimeIntervalSince1970:ts];
        f.isValid = YES;
        if ([r[@"sa"] isKindOfClass:NSString.class]) f.shortAddress = r[@"sa"];
        if ([r[@"la"] isKindOfClass:NSString.class]) f.longAddress = r[@"la"];
        StoreFix(hid, (FMFLocation *)f);
        stored++;
    }
    @synchronized (gLock) { gLastIngest = [NSDate date].timeIntervalSince1970; }
    return stored;
}

static BOOL TweakAnsweredSince(NSTimeInterval since, NSTimeInterval timeout) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([end timeIntervalSinceNow] > 0) {
        @synchronized (gLock) { if (gLastIngest > since) return YES; }
        usleep(100 * 1000);
    }
    return NO;
}

static pid_t MessagesPid(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || !len) return 0;
    struct kinfo_proc *procs = malloc(len);
    pid_t pid = 0;
    if (procs && sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        for (size_t i = 0; i < len / sizeof(*procs); i++) {
            if (!strcmp(procs[i].kp_proc.p_comm, "MobileSMS")) { pid = procs[i].kp_proc.p_pid; break; }
        }
    }
    free(procs);
    return pid;
}

// The tweak only sees locations while Messages runs, and iOS suspends it in
// the background. A running Messages answers a ping at once; silence means it
// is suspended or gone, so close it and relaunch it in the background, which
// gives the tweak a ~27s background task to catch the refresh. Resuming it in
// place is not possible: RunningBoard only lets SpringBoard assert on apps.
// ponytail: closing a suspended Messages costs the user a cold start next time.
static void WakeMessages(void) {
    NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
    notify_post("io.github.jjoelj.lss.fmf-ping");
    if (TweakAnsweredSince(t0, 1.5)) return;

    static int (*launch)(CFStringRef, Boolean);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        launch = sbs ? (int (*)(CFStringRef, Boolean))dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
    });
    pid_t pid = MessagesPid();
    if (pid > 0) {
        kill(pid, SIGKILL);
        usleep(500 * 1000);
    }
    int r = launch ? launch(CFSTR("com.apple.MobileSMS"), true) : -1;
    BOOL up = r == 0 && TweakAnsweredSince(t0, 10);
    Log([NSString stringWithFormat:@"watch Messages %@, relaunched in background (%d), tweak %@",
        pid > 0 ? @"was suspended" : @"was not running", r, up ? @"answered" : @"did not answer"]);
}

// FMLFriend -> FMLHandle, keyed by identifier.
static NSDictionary<NSString *, id> *FMLHandlesById(id friends) {
    id v = [friends respondsToSelector:@selector(allObjects)] ? [friends allObjects] : friends;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![v respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return out;
    for (id f in v) {
        id h = [f respondsToSelector:@selector(handle)] ? [f handle] : nil;
        NSString *hid = [h respondsToSelector:@selector(identifier)] ? [h identifier] : nil;
        if (hid.length) out[hid] = h;
    }
    return out;
}

@interface FMFWatchDelegate : NSObject
@end
@implementation FMFWatchDelegate
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

static void ApplyHandles(NSDictionary<NSString *, id> *loadedById) {
        NSArray *handles = loadedById.allValues;
        NSMutableSet<NSString *> *loadedIds = [NSMutableSet setWithArray:loadedById.allKeys];
        // Swap in whole, not clear-then-fill: this now runs on a timer, and the
        // old in-place rebuild left a window where /friends read an empty set.
        BOOL discovered;
        @synchronized (gLock) {
            discovered = gHandlesLoaded && ![loadedIds isSubsetOfSet:gKnownIds];
            gKnownIds = loadedIds;
            gHandlesById = [loadedById mutableCopy];
            gHandlesLoaded = YES;
        }
        if (!gFML) [gSession setHandles:[NSSet setWithArray:handles]];
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
}

static void LoadHandles(void) {
    if (gFML) {
        [gFMLSession getFriendsSharingLocationsWithMeWithCompletion:^(id friends) {
            ApplyHandles(FMLHandlesById(friends));
        }];
        return;
    }
    [gSession getHandlesSharingLocationsWithMeWithGroupId:nil completion:^(NSArray *ids) {
        NSArray *idArray = [ids respondsToSelector:@selector(allObjects)] ? [(id)ids allObjects] : ids;
        NSMutableDictionary<NSString *, FMFHandle *> *loadedById = [NSMutableDictionary dictionary];
        for (id x in idArray) {
            NSString *identifier = [x isKindOfClass:NSString.class] ? x : [x description];
            if (!identifier.length) continue;
            FMFHandle *h = [gHandleCls handleWithId:identifier];
            if (h) loadedById[identifier] = h;
        }
        ApplyHandles(loadedById);
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

    if (gFML) {
        // 1000 is BlueBubbles' working value; FML priorities are not FMF's.
        Log([NSString stringWithFormat:@"watch FML startRefreshing count=%lu", (unsigned long)handles.count]);
        NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
        [gFMLSession startRefreshingLocationForHandles:handles priority:1000 isFromGroup:NO
                                        reverseGeocode:NO completion:^{
            Log([NSString stringWithFormat:@"watch FML startRefreshing completion after %.1fs",
                [NSDate date].timeIntervalSince1970 - t0]);
        }];
        return;
    }

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

        WakeMessages();

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
// One CLGeocoder shared, throttled requests just retry next read.
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

// --- Sharing my own location -------------------------------------------
// fmfd's XPC completion blocks are declared as bare "some block" in the
// protocol, so their argument shapes are guesswork -- reading them wrong means
// dereferencing a BOOL as a pointer. We take a no-arg block (extra arguments
// are harmless on arm64) and confirm the result by re-reading the follower
// list instead of trusting a completion we cannot type.

static NSArray<NSString *> *StringIds(id ids) {
    id v = [ids respondsToSelector:@selector(allObjects)] ? [ids allObjects] : ids;
    if (![v respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id x in v) {
        NSString *s = [x isKindOfClass:NSString.class] ? x : [x description];
        if (s.length) [out addObject:s];
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

// Handles that can see my location right now. nil if fmfd did not answer.
static NSArray<NSString *> *FollowingMyLocation(void) {
    __block NSArray<NSString *> *out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    if (gFML) {
        [gFMLSession getFriendsFollowingMyLocationWithCompletion:^(id friends) {
            out = [FMLHandlesById(friends).allKeys sortedArrayUsingSelector:@selector(compare:)];
            dispatch_semaphore_signal(sem);
        }];
    } else {
        [gSession getHandlesFollowingMyLocationWithGroupId:nil completion:^(NSArray *ids) {
            out = StringIds(ids);
            dispatch_semaphore_signal(sem);
        }];
    }
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShareDeadline * NSEC_PER_SEC)));
    return out;
}

static NSDictionary *FollowingJSONObject(void) {
    NSArray *following = FollowingMyLocation();
    if (!following) return @{@"ok": @NO, @"message": @"fmfd did not answer"};
    return @{@"ok": @YES, @"following": following};
}

// share=YES sends a "Share My Location" offer (the recipient is notified and
// can see me from then on); share=NO revokes it. endDate nil shares
// indefinitely, matching Find My's "Share Indefinitely".
// "+1 555-010-0199" -> "+15550100199". fmfd only IDS-validates the bare form;
// a formatted number still gets a 200 from the offer, but no IDS mapping
// packet goes to the recipient, so their Find My shows "No location found".
// Emails pass through. Share only: unshare must match the handle exactly as
// stored, and older shares were stored formatted.
static NSString *BareHandle(NSString *hid) {
    if ([hid containsString:@"@"]) return hid;
    NSCharacterSet *drop = [[NSCharacterSet characterSetWithCharactersInString:@"+0123456789"] invertedSet];
    return [[hid componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

static NSDictionary *SetSharing(NSString *hid, BOOL share, NSDate *endDate) {
    if (share) hid = BareHandle(hid);
    if (!hid.length) return @{@"ok": @NO, @"message": @"missing handle"};
    // ponytail: FML's offer takes an undocumented `expiration` long long; a
    // wrong guess shares for the wrong duration. Unsupported until verified.
    if (gFML && share) return @{@"ok": @NO, @"message": @"sharing not supported on iOS 17+ yet"};
    FMFHandle *h = gFML ? [gHandleCls handleWithIdentifier:hid] : [gHandleCls handleWithId:hid];
    if (!h) return @{@"ok": @NO, @"message": @"bad handle"};

    Log([NSString stringWithFormat:@"watch %@ handle=%@ until=%@",
        share ? @"share" : @"unshare", hid, endDate ?: @"never"]);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id done = ^{ dispatch_semaphore_signal(sem); };
    if (gFML) {
        [gFMLSession stopSharingLocationWith:h isFromGroup:NO completion:done];
    } else if (share) {
        [gSession sendFriendshipOfferToHandle:h groupId:nil callerId:nil endDate:endDate completion:done];
    } else {
        [gSession stopSharingMyLocationWithHandle:h groupId:nil callerId:nil completion:done];
    }
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShareDeadline * NSEC_PER_SEC)));

    NSArray *following = FollowingMyLocation();
    BOOL sharing = [following containsObject:hid];
    Log([NSString stringWithFormat:@"watch %@ done handle=%@ sharing=%d",
        share ? @"share" : @"unshare", hid, sharing]);
    return @{@"ok": @YES, @"handle": hid, @"sharing": @(sharing), @"following": following ?: @[]};
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
    dispatch_source_set_event_handler(gAutoRefreshSource, ^{ TrimLog(); LoadHandles(); MaybeAutoRefresh(); });
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
    // Headers first; only POST /ingest (from the Messages tweak) has a body.
    NSMutableData *buf = [NSMutableData data];
    NSData *sep = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange headEnd = NSMakeRange(NSNotFound, 0);
    char chunk[4096];
    while (headEnd.location == NSNotFound && buf.length < 16384) {
        ssize_t n = read(cfd, chunk, sizeof(chunk));
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
        headEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
    }
    // A bare connect-and-close (locationspoofd's liveness probe) sends nothing;
    // replying to it would write to a closed socket.
    if (headEnd.location == NSNotFound) { close(cfd); return; }
    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headEnd.location)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *req = [lines.firstObject componentsSeparatedByString:@" "];
    NSString *method = req.count >= 2 ? req[0] : @"";
    NSString *t = req.count >= 2 ? req[1] : @"";

    if ([method isEqualToString:@"POST"] && [t isEqualToString:@"/ingest"]) {
        NSUInteger want = 0;
        for (NSString *l in lines) {
            if ([l.lowercaseString hasPrefix:@"content-length:"]) want = (NSUInteger)[l substringFromIndex:15].integerValue;
        }
        NSUInteger start = NSMaxRange(headEnd);
        NSMutableData *body = [[buf subdataWithRange:NSMakeRange(start, buf.length - start)] mutableCopy];
        while (body.length < want && body.length < (1 << 20)) {
            ssize_t n = read(cfd, chunk, sizeof(chunk));
            if (n <= 0) break;
            [body appendBytes:chunk length:(NSUInteger)n];
        }
        WriteHTTP(cfd, 200, [NSString stringWithFormat:@"{\"ok\":true,\"stored\":%lu}", (unsigned long)Ingest(body)]);
        close(cfd);
        return;
    }
    if (![method isEqualToString:@"GET"]) {
        WriteHTTP(cfd, 400, @"{\"ok\":false,\"message\":\"bad request\"}");
        close(cfd);
        return;
    }

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
    } else if ([path isEqualToString:@"/following"] ||
               [path isEqualToString:@"/share"] ||
               [path isEqualToString:@"/unshare"]) {
        NSDictionary *result;
        if ([path isEqualToString:@"/following"]) {
            result = FollowingJSONObject();
        } else {
            double hours = [q[@"hours"] doubleValue];
            NSDate *endDate = hours > 0 ?
                [NSDate dateWithTimeIntervalSinceNow:hours * 3600] : nil;
            result = SetSharing(q[@"handle"], [path isEqualToString:@"/share"], endDate);
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"ok\":false}";
        WriteHTTP(cfd, [result[@"ok"] boolValue] ? 200 : 400, body);
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
        // A client hanging up mid-reply must cost that reply, not the process.
        signal(SIGPIPE, SIG_IGN);
        TrimLog();
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

        Class fmlCls = Nil;
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 &&
            dlopen("/System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework/FindMyLocateObjCWrapper", RTLD_NOW)) {
            fmlCls = objc_getClass("FindMyLocateSession");
        }
        if (fmlCls) {
            gFML = YES;
            gHandleCls = objc_getClass("FMLHandle");
            gFMLSession = [fmlCls new];
            Log([NSString stringWithFormat:@"watch backend: FindMyLocate (iOS %@)",
                NSProcessInfo.processInfo.operatingSystemVersionString]);
            // Never register setLocationUpdateCallback: on iOS 18 the push of a
            // decrypted location SIGKILLs this process. Locates still work
            // without it, and Messages (the tweak) receives the results.
            if ([gFMLSession respondsToSelector:@selector(setFriendshipUpdateCallback:)]) {
                [gFMLSession setFriendshipUpdateCallback:^{ ScheduleLoadHandles(@"FML friendshipUpdateCallback"); }];
            }
            [gFMLSession startUpdatingFriendsWithInitialUpdates:YES completion:^{
                ScheduleLoadHandles(@"FML startUpdatingFriends");
            }];
            LoadHandles();
            StartHTTPServer();
            StartAutoRefreshTimer();
            [[NSRunLoop currentRunLoop] run];
            return 0;
        }

        if (!dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW)) {
            Log(@"FMFCore unavailable");
            return 1;
        }

        gHandleCls = objc_getClass("FMFHandle");
        Class sessionCls = objc_getClass("FMFSession");

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

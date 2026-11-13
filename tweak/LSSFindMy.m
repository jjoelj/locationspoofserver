// LSSFindMy: loaded into Messages. Reads friends' locations through Messages'
// own Find My client (IMCore's IMFMFSession) and hands them to fmfwatchd over
// localhost (POST 127.0.0.1:8766/ingest).
//
// Why Messages: on iOS 17+ friend locations are end-to-end encrypted, and iOS
// SIGKILLs a standalone daemon the moment one is delivered to it. Messages is
// entitled to decrypt them, and its client returns the same account-wide
// friends list as Find My, no chats needed. One path for every iOS version.
//
// fmfwatchd still lists friends and triggers the locates (Messages' own refresh
// is ignored while it is in the background); this only listens and forwards.
//
// No hooks, so it needs a loader but links no Substrate/libhooker. Every
// IMCore call is guarded and made on the main queue (IMCore asserts it), so a
// moved selector costs a location, never Messages itself.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <Block.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <notify.h>
#include <sys/socket.h>
#include <unistd.h>

// Object-returning sends only; a BOOL or double through these would be misread.
static id Send(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!o || ![o respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(o, s); } @catch (NSException *e) { return nil; }
}

static id Send1(id o, NSString *sel, id a) {
    SEL s = NSSelectorFromString(sel);
    if (!o || ![o respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(o, s, a); } @catch (NSException *e) { return nil; }
}

static double SendD(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!o || ![o respondsToSelector:s]) return 0;
    @try { return ((double (*)(id, SEL))objc_msgSend)(o, s); } @catch (NSException *e) { return 0; }
}

static NSArray *Coll(id v) {
    if ([v isKindOfClass:NSArray.class]) return v;
    if ([v respondsToSelector:@selector(allObjects)]) return [v allObjects];
    return @[];
}

static id Session(void) {
    Class c = objc_getClass("IMFMFSession");
    return c ? Send((id)c, @"sharedInstance") : nil;
}

// FMLLocation.timestamp is a bare double of undeclared unit; the magnitude
// tells (as BlueBubbles does): ms since 1970, seconds since 2001, or 1970.
static double Seconds1970(double raw) {
    if (raw > 1e11) return raw / 1000;
    if (raw > 0 && raw < 1e9) return raw + NSTimeIntervalSince1970;
    return raw;
}

// One /ingest row, or nil when there's no usable fix. `loc` is an
// IMFindMyLocation (iOS 17+, wraps an FMLLocation and/or FMFLocation) or a
// bare FMFLocation (iOS <=16).
static NSDictionary *Row(NSString *hid, id loc) {
    if (!hid.length || !loc) return nil;
    NSString *wrapperShort = Send(loc, @"shortAddress");
    id fml = Send(loc, @"fmlLocation");
    id fmf = Send(loc, @"fmfLocation") ?: (fml ? nil : loc);
    double lat = 0, lon = 0, acc = 0, ts = 0;
    NSString *sa = nil, *la = nil;

    if (fml) {
        lat = SendD(fml, @"latitude");
        lon = SendD(fml, @"longitude");
        acc = SendD(fml, @"horizontalAccuracy");
        ts = Seconds1970(SendD(fml, @"timestamp"));
        id lines = Send(Send(fml, @"address"), @"formattedAddressLines");
        if ([lines isKindOfClass:NSArray.class]) la = [lines componentsJoinedByString:@"\n"];
    } else {
        id cl = Send(fmf, @"location");
        if (![cl isKindOfClass:CLLocation.class]) return nil;
        CLLocation *c = cl;
        lat = c.coordinate.latitude;
        lon = c.coordinate.longitude;
        acc = c.horizontalAccuracy;
        id t = Send(fmf, @"timestamp");
        ts = [t isKindOfClass:NSDate.class] ? [(NSDate *)t timeIntervalSince1970] : 0;
        sa = Send(fmf, @"shortAddress");
        la = Send(fmf, @"longAddress");
    }
    if ((lat == 0 && lon == 0) || ts <= 0) return nil;
    NSMutableDictionary *r = [@{@"h": hid, @"lat": @(lat), @"lon": @(lon), @"acc": @(acc), @"ts": @(ts)} mutableCopy];
    NSString *shortA = [wrapperShort isKindOfClass:NSString.class] && wrapperShort.length ? wrapperShort : sa;
    if ([shortA isKindOfClass:NSString.class] && shortA.length) r[@"sa"] = shortA;
    if ([la isKindOfClass:NSString.class] && la.length) r[@"la"] = la;
    return r;
}

static void Post(NSArray *rows) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    if (!body) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        // Without this, writing after fmfwatchd hangs up raises SIGPIPE, which
        // would kill Messages. Messages' own signal handling stays untouched.
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        struct sockaddr_in a = {0};
        a.sin_family = AF_INET;
        a.sin_port = htons(8766);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
            NSString *head = [NSString stringWithFormat:@"POST /ingest HTTP/1.0\r\nContent-Type: application/json\r\n"
                                                         @"Content-Length: %lu\r\n\r\n", (unsigned long)body.length];
            NSMutableData *req = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            [req appendData:body];
            const uint8_t *p = req.bytes;
            size_t left = req.length;
            while (left > 0) {
                ssize_t n = write(fd, p, left);
                if (n <= 0) break;
                p += n;
                left -= (size_t)n;
            }
            char sink[256];
            (void)read(fd, sink, sizeof(sink));
        }
        close(fd);
    });
}

// Every friend's current location, posted in one batch. Main queue only.
static void SendSnapshot(void) {
    id s = Session();
    if (!s) return;

    // iOS 17+: IMCore picks FindMyLocate or FMF behind these selectors.
    if ([s respondsToSelector:NSSelectorFromString(@"findMyHandlesSharingLocationWithMe")]) {
        NSMutableArray *rows = [NSMutableArray array];
        for (id h in Coll(Send(s, @"findMyHandlesSharingLocationWithMe"))) {
            NSDictionary *r = Row(Send(h, @"identifier"), Send1(s, @"findMyLocationForFindMyHandle:", h));
            if (r) [rows addObject:r];
        }
        if (rows.count) Post(rows);
        return;
    }

    // iOS <=16: Messages' FMFSession; the handle list arrives asynchronously.
    id fmf = Send(s, @"session");
    SEL get = NSSelectorFromString(@"getHandlesSharingLocationsWithMeWithGroupId:completion:");
    Class hc = objc_getClass("FMFHandle");
    if (![fmf respondsToSelector:get] || !hc) return;
    void (^done)(id) = ^(id ids) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *rows = [NSMutableArray array];
            for (id x in Coll(ids)) {
                NSString *hid = [x isKindOfClass:NSString.class] ? x : (Send(x, @"identifier") ?: [x description]);
                id h = Send1((id)hc, @"handleWithId:", hid);
                NSDictionary *r = Row(hid, Send1(s, @"locationForFMFHandle:", h));
                if (r) [rows addObject:r];
            }
            if (rows.count) Post(rows);
        });
    };
    @try { ((void (*)(id, SEL, id, id))objc_msgSend)(fmf, get, nil, done); } @catch (NSException *e) {}
}

// Locations arrive in bursts, one notification per friend; batch them.
static void SnapshotSoon(void) {
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pending = NO;
        SendSnapshot();
    });
}

// In the background iOS suspends Messages within seconds; a background task
// keeps it running ~27s, long enough for a refresh fmfwatchd triggers to land.
static void StayAwake(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app || app.applicationState == UIApplicationStateActive) return;
    __block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
    // Heap-copied before UIKit sees it: LLVM 19 leaves a stack block's isa
    // unsigned and iOS 18's objc_msgSend rejects it. C APIs copy blocks
    // themselves; only capturing blocks handed to Obj-C need this.
    void (^end)(void) = (__bridge_transfer void (^)(void))_Block_copy((__bridge const void *)^{
        if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    });
    bg = [app beginBackgroundTaskWithExpirationHandler:end];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), end);
}

__attribute__((constructor)) static void LSSFindMyInit(void) {
    for (NSString *n in @[@"__kIMFMFSessionLocationReceivedNotification",
                          @"__kIMFMFSessionHandleLocationRefreshedNotification",
                          @"__kIMFMFSessionRelationshipStatusDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { SnapshotSoon(); }];
    }

    // Launched in the background by fmfwatchd (or by the user): answer at once
    // so fmfwatchd knows we're up, then send what Messages already has.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        StayAwake();
        Post(@[]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SendSnapshot(); });
    }];

    // fmfwatchd's "are you there?" before a refresh. A suspended Messages never
    // sees it, and that silence is how fmfwatchd knows to relaunch us.
    int token;
    notify_register_dispatch("io.github.jjoelj.lss.fmf-ping", &token, dispatch_get_main_queue(), ^(int t) {
        StayAwake();
        Post(@[]);
        SendSnapshot();
    });
}

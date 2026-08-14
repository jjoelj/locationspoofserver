#import "LSSDaemonController.h"
#import "LSSLogger.h"
#import "LSSLocalHTTPServer.h"
#import "LSSLocSimController.h"
#import <CoreLocation/CoreLocation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <math.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

static const int kFMFWatchPort = 8766;

// Random per-device token, persisted so it survives daemon restarts (otherwise
// the external pusher's saved token would break on every relaunch). Not in git.
static NSString *const kTokenPath = @"/var/mobile/Library/LocationSpoofServer/set-token";

static NSString *GenerateToken(void) {
    uint8_t b[16];
    arc4random_buf(b, sizeof(b));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (size_t i = 0; i < sizeof(b); i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static void SaveToken(NSString *tok) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[kTokenPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [tok writeToFile:kTokenPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *LoadOrCreateToken(void) {
    NSString *existing = [NSString stringWithContentsOfFile:kTokenPath encoding:NSUTF8StringEncoding error:nil];
    existing = [existing stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing.length > 0) return existing;

    NSString *tok = GenerateToken();
    SaveToken(tok);
    return tok;
}

static NSString *FriendsSummary(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) return @"invalid json";

    if (![obj[@"ok"] boolValue]) {
        NSString *message = [obj[@"message"] isKindOfClass:[NSString class]] ? obj[@"message"] : @"unknown error";
        return [NSString stringWithFormat:@"failed: %@", message];
    }

    NSArray *friends = [obj[@"friends"] isKindOfClass:[NSArray class]] ? obj[@"friends"] : @[];
    NSUInteger valid = 0;
    for (NSDictionary *f in friends) {
        if (![f isKindOfClass:[NSDictionary class]]) continue;
        if ([f[@"valid"] boolValue]) valid++;
    }
    return [NSString stringWithFormat:@"ok: %lu friends, %lu valid locations",
            (unsigned long)friends.count, (unsigned long)valid];
}

static NSDictionary *ReadBatteryStatus(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return @{@"ok": @NO, @"message": @"battery info unavailable"};

    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (!sources) {
        CFRelease(info);
        return @{@"ok": @NO, @"message": @"battery source unavailable"};
    }

    NSMutableDictionary *battery = nil;
    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, i);
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, source);
        if (!desc) continue;

        NSDictionary *d = (__bridge NSDictionary *)desc;
        NSString *currentKey = @(kIOPSCurrentCapacityKey);
        NSString *maxKey = @(kIOPSMaxCapacityKey);
        NSString *stateKey = @(kIOPSPowerSourceStateKey);
        NSString *chargingKey = @(kIOPSIsChargingKey);

        NSNumber *current = [d[currentKey] isKindOfClass:[NSNumber class]] ? d[currentKey] : nil;
        NSNumber *max = [d[maxKey] isKindOfClass:[NSNumber class]] ? d[maxKey] : nil;
        if (!current || !max || max.integerValue <= 0) continue;

        NSInteger percent = (NSInteger)llround(((double)current.integerValue * 100.0) / (double)max.integerValue);
        percent = MAX((NSInteger)0, MIN((NSInteger)100, percent));

        NSString *state = [d[stateKey] isKindOfClass:[NSString class]] ? d[stateKey] : @"";
        NSNumber *isCharging = [d[chargingKey] isKindOfClass:[NSNumber class]] ? d[chargingKey] : nil;
        BOOL externalPower = [state isEqualToString:@kIOPSACPowerValue];
        BOOL charging = isCharging ? isCharging.boolValue : externalPower;

        battery = [@{
            @"ok": @YES,
            @"batteryPercent": @(percent),
            @"batteryLevel": @((double)percent / 100.0),
            @"charging": @(charging),
            @"externalPower": @(externalPower),
        } mutableCopy];
        break;
    }

    CFRelease(sources);
    CFRelease(info);

    return battery ?: @{@"ok": @NO, @"message": @"battery not found"};
}

// Liveness by connecting, not by scanning the process table: a daemon that is
// running but not accepting connections is not useful to anyone here.
static BOOL TCPPortOpen(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    BOOL ok = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    return ok;
}

static BOOL UnixSocketAlive(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));

    // A stale socket file left by a dead daemon refuses the connection, which
    // is exactly the distinction we want.
    BOOL ok = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    return ok;
}

static NSString *URLEncode(NSString *s) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *FMFWatchRequest(NSString *path, NSString *handle, int *statusOut) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (statusOut) *statusOut = 0;
        return @"{\"ok\":false,\"message\":\"fmfwatchd socket failed\"}";
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)kFMFWatchPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        if (statusOut) *statusOut = 0;
        return @"{\"ok\":false,\"message\":\"fmfwatchd unavailable\"}";
    }

    NSString *target = path;
    if (handle.length) {
        target = [target stringByAppendingFormat:@"?handle=%@", URLEncode(handle)];
    }
    NSString *req = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", target];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(fd, reqData.bytes, reqData.length);

    NSMutableData *resp = [NSMutableData data];
    uint8_t buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) [resp appendBytes:buf length:(size_t)n];
    close(fd);

    NSString *raw = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    if (!raw.length) {
        if (statusOut) *statusOut = 0;
        return @"{\"ok\":false,\"message\":\"fmfwatchd empty response\"}";
    }

    NSArray<NSString *> *lines = [raw componentsSeparatedByString:@"\r\n"];
    int status = 0;
    if (lines.count > 0) sscanf(lines[0].UTF8String, "HTTP/%*s %d", &status);
    if (statusOut) *statusOut = status;

    NSRange sep = [raw rangeOfString:@"\r\n\r\n"];
    if (sep.location == NSNotFound) return @"{\"ok\":false,\"message\":\"fmfwatchd bad response\"}";
    return [raw substringFromIndex:sep.location + sep.length];
}

static const char *kTSCLI = "/usr/local/bin/tailscale --socket=/var/run/lss-tailscaled.socket";

// Run a tailscale CLI command, logging every line it prints (stderr included --
// that is where `up` puts the login URL) and handing each to `onLine`.
static int RunTS(NSString *args, void (^onLine)(NSString *line)) {
    NSString *cmd = [NSString stringWithFormat:@"%s %@ 2>&1", kTSCLI, args];
    FILE *p = popen(cmd.UTF8String, "r");
    if (!p) return -1;

    char buf[1024];
    while (fgets(buf, sizeof(buf), p)) {
        NSString *line = [@(buf) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;
        [[LSSLogger shared] log:line tag:@"TAILSCALE"];
        if (onLine) onLine(line);
    }
    return pclose(p);
}

@interface LSSDaemonController ()
@property(nonatomic, strong) LSSLocalHTTPServer *publicServer;
@property(nonatomic, copy, nullable) NSString *cachedPublicURL;
@property(nonatomic, copy, nullable) NSString *pendingLoginURL;
@end

@implementation LSSDaemonController

+ (instancetype)shared {
    static LSSDaemonController *g;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g = [[LSSDaemonController alloc] init];
    });
    return g;
}

- (instancetype)init {
    if ((self = [super init])) {
        _publicPort = 8080;

        NSDictionary *env = NSProcessInfo.processInfo.environment;
        _setEndpointToken = env[@"LSS_SET_TOKEN"] ?: LoadOrCreateToken();
    }
    return self;
}

- (void)startServices {
    [[LSSLogger shared] log:@"daemon starting services" tag:@"DAEMON"];

    (void)[LSSLocSimController shared];

    self.publicServer = [[LSSLocalHTTPServer alloc] init];
    self.publicServer.authToken = self.setEndpointToken;

    self.publicServer.locationSink = ^(double lat, double lon) {
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lon);
        if (!CLLocationCoordinate2DIsValid(c)) {
            [[LSSLogger shared] log:[NSString stringWithFormat:@"reject invalid lat/lon %.6f %.6f", lat, lon] tag:@"LOCSIM"];
            return;
        }

        CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
        [[LSSLocSimController shared] pushLocation:loc];
        [[LSSLogger shared] log:[NSString stringWithFormat:@"applied lat=%.6f lon=%.6f", lat, lon] tag:@"LOCSIM"];
    };

    [self.publicServer startOnPort:self.publicPort];
    [[LSSLogger shared] log:[NSString stringWithFormat:@"public server on 127.0.0.1:%d", self.publicPort] tag:@"DAEMON"];
}

// Shell out to the tailscale CLI instead of speaking to tailscaled's
// local API ourselves. One process spawn per call until it succeeds, then
// cached for the life of the daemon. Re-exec if you move to a different tailnet.
- (nullable NSString *)publicURL {
    // Cache only successes: this daemon starts before tailscaled has logged in,
    // so the first call usually fails and must not be remembered. Logging in
    // from the app clears it, since that is when the name can change.
    @synchronized (self) {
        if (self.cachedPublicURL) return self.cachedPublicURL;
    }

    FILE *p = popen("/usr/local/bin/tailscale --socket=/var/run/lss-tailscaled.socket "
                    "status --json 2>/dev/null", "r");
    if (!p) return nil;

    NSMutableData *out = [NSMutableData data];
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), p)) > 0) [out appendBytes:buf length:n];
    if (pclose(p) != 0 || out.length == 0) {
        [[LSSLogger shared] log:@"tailscale status unavailable" tag:@"DAEMON"];
        return nil;
    }

    NSDictionary *st = [NSJSONSerialization JSONObjectWithData:out options:0 error:nil];
    if (![st isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *me = st[@"Self"];
    if (![me isKindOfClass:[NSDictionary class]]) return nil;

    NSString *name = me[@"DNSName"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    // DNSName comes back fully qualified, with the trailing root dot.
    if ([name hasSuffix:@"."]) name = [name substringToIndex:name.length - 1];

    NSString *url = [NSString stringWithFormat:@"https://%@", name];
    @synchronized (self) {
        self.cachedPublicURL = url;
    }
    [[LSSLogger shared] log:[NSString stringWithFormat:@"public url %@", url] tag:@"DAEMON"];
    return url;
}

// `tailscale up` prints a login URL and then blocks until the user finishes in
// a browser, so it runs on its own queue while this call waits just long enough
// to catch the URL. Finishing the login is what opens the Funnel.
- (NSDictionary *)tailscaleLogin {
    @synchronized (self) {
        if (self.pendingLoginURL) return @{@"ok": @YES, @"loginURL": self.pendingLoginURL};
    }

    __block NSString *loginURL = nil;
    __block NSString *lastLine = @"";
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int rc = RunTS(@"up --hostname=iphone", ^(NSString *line) {
            lastLine = line;
            if (loginURL || ![line hasPrefix:@"https://"]) return;
            loginURL = line;
            @synchronized (self) { self.pendingLoginURL = line; }
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_signal(done); // no URL printed: already logged in, or failed

        @synchronized (self) { self.pendingLoginURL = nil; }
        if (rc != 0) {
            [[LSSLogger shared] log:[NSString stringWithFormat:@"tailscale up failed (%d)", rc] tag:@"DAEMON"];
            return;
        }

        @synchronized (self) { self.cachedPublicURL = nil; } // name may have changed
        RunTS([NSString stringWithFormat:@"funnel --bg %d", self.publicPort], nil);
        [self publicURL]; // logs the URL the app is about to pick up
    });

    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

    if (loginURL) return @{@"ok": @YES, @"loginURL": loginURL};
    if ([self publicURL]) return @{@"ok": @YES, @"loginURL": @""}; // already logged in
    return @{@"ok": @NO, @"loginURL": @"", @"message": lastLine.length ? lastLine : @"tailscale up gave no login link"};
}

- (NSDictionary *)tailscaleLogout {
    int rc = RunTS(@"logout", nil);
    @synchronized (self) { self.cachedPublicURL = nil; }
    if (rc != 0) return @{@"ok": @NO, @"message": [NSString stringWithFormat:@"tailscale logout failed (%d)", rc]};
    [[LSSLogger shared] log:@"logged out of tailscale" tag:@"DAEMON"];
    return @{@"ok": @YES, @"message": @"logged out"};
}

- (NSDictionary *)daemonStatus {
    return @{
        // We are answering this request, so we are up by definition.
        @"locationspoofd": @YES,
        @"fmfwatchd": @(TCPPortOpen((uint16_t)kFMFWatchPort)),
        @"tailscaled": @(UnixSocketAlive("/var/run/lss-tailscaled.socket")),
    };
}

- (NSDictionary *)regenerateToken {
    NSString *tok = GenerateToken();
    SaveToken(tok);
    self.setEndpointToken = tok;
    self.publicServer.authToken = tok;
    [[LSSLogger shared] log:@"set token regenerated" tag:@"DAEMON"];
    return @{@"ok": @YES, @"token": tok};
}

- (NSString *)friendsJSON {
    return FMFWatchRequest(@"/friends", nil, NULL);
}

- (NSString *)friendsJSONForHandle:(NSString *)handle {
    return FMFWatchRequest(@"/friends", handle, NULL);
}

- (NSString *)refreshFriendsJSONForHandle:(NSString *)handle ifStarted:(BOOL *)started {
    NSDate *start = [NSDate date];
    NSString *target = handle.length ? [NSString stringWithFormat:@" for handle=%@", handle] : @"";
    [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh started%@", target] tag:@"FMF"];
    int status = 0;
    NSString *json = FMFWatchRequest(@"/refresh", handle, &status);
    if (started) *started = (status != 409);
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];
    [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh finished in %.1fs (%@)", elapsed, FriendsSummary(json)] tag:@"FMF"];
    return json;
}

- (NSDictionary *)batteryStatus {
    return ReadBatteryStatus();
}

- (NSDictionary *)logs {
    return @{@"ok": @YES, @"logs": [[LSSLogger shared] snapshot] ?: @""};
}

@end

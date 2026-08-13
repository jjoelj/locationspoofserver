#import "LSSLocalHTTPServer.h"
#import "LSSLogger.h"
#import "LSSLocSimController.h"
#import "LSSDaemonController.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

@interface LSSLocalHTTPServer ()
@property(nonatomic, assign) int listenFD;
@property(nonatomic, strong) dispatch_source_t acceptSource;
@property(nonatomic, assign) int port;
@end

@implementation LSSLocalHTTPServer

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _port = -1;
    }
    return self;
}

- (void)log:(NSString *)line {
    [[LSSLogger shared] log:line tag:@"HTTP"];
}

static NSString *URLDecode(NSString *s) {
    return [s stringByRemovingPercentEncoding] ?: s;
}

static NSDictionary<NSString *, NSString *> *ParseQuery(NSString *query) {
    if (query.length == 0) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (pair.length == 0) continue;
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        NSString *k = URLDecode(kv.count > 0 ? kv[0] : @"");
        NSString *v = URLDecode(kv.count > 1 ? kv[1] : @"");
        if (k.length) out[k] = v ?: @"";
    }
    return out;
}

static void WriteHTTP(int fd, int status, const char *statusText, const char *body) {
    if (!body) body = "";
    size_t bodyLen = strlen(body);

    char hdr[512];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, statusText, bodyLen);

    (void)write(fd, hdr, (size_t)n);
    if (bodyLen) (void)write(fd, body, bodyLen);
}

static void WriteJSONBody(int fd, int status, const char *statusText, NSString *json) {
    NSData *body = [json dataUsingEncoding:NSUTF8StringEncoding];
    char hdr[256];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\nConnection: close\r\n\r\n",
        status, statusText, (size_t)body.length);
    (void)write(fd, hdr, (size_t)hn);
    (void)write(fd, body.bytes, body.length);
}

static void WriteJSON(int fd, int status, const char *statusText, NSDictionary *obj) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!body) body = [@"{\"ok\":false,\"message\":\"json encode failed\"}" dataUsingEncoding:NSUTF8StringEncoding];

    char hdr[256];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\nConnection: close\r\n\r\n",
        status, statusText, (size_t)body.length);
    (void)write(fd, hdr, (size_t)hn);
    (void)write(fd, body.bytes, body.length);
}

- (void)handleClient:(int)cfd {
    // Read request (simple, assumes it fits in buffer for this test)
    char buf[4096];
    ssize_t n = read(cfd, buf, sizeof(buf) - 1);
    if (n <= 0) { close(cfd); return; }
    buf[n] = 0;

    // Parse first line: "GET /path?query HTTP/1.1"
    char method[8] = {0};
    char target[2048] = {0};
    if (sscanf(buf, "%7s %2047s", method, target) != 2) {
        WriteHTTP(cfd, 400, "Bad Request", "bad request\n");
        close(cfd);
        return;
    }

    NSString *m = [NSString stringWithUTF8String:method] ?: @"";
    NSString *t = [NSString stringWithUTF8String:target] ?: @"";

    [self log:[NSString stringWithFormat:@"%@ %@", m, t]];

    if (![m isEqualToString:@"GET"]) {
        WriteHTTP(cfd, 405, "Method Not Allowed", "use GET\n");
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

    if ([path isEqualToString:@"/"]) {
        WriteHTTP(cfd, 200, "OK", "ok\n");
        close(cfd);
        return;
    }

    if ([path isEqualToString:@"/friends"] || [path isEqualToString:@"/friends/refresh"]) {
        NSDictionary *q = ParseQuery(query);
        NSString *token = q[@"token"];
        if (token == nil || ![token isEqualToString:self.authToken]) {
            WriteHTTP(cfd, 403, "Forbidden", "invalid or missing token\n");
            close(cfd);
            return;
        }
        BOOL refresh = [path isEqualToString:@"/friends/refresh"];
        BOOL started = YES;
        NSString *handle = q[@"handle"];
        NSString *json = refresh ?
            [[LSSDaemonController shared] refreshFriendsJSONForHandle:handle ifStarted:&started] :
            [[LSSDaemonController shared] friendsJSONForHandle:handle];
        WriteJSONBody(cfd, started ? 200 : 409, started ? "OK" : "Conflict", json);
        close(cfd);
        return;
    }

    if ([path isEqualToString:@"/battery"]) {
        NSDictionary *q = ParseQuery(query);
        NSString *token = q[@"token"];
        if (token == nil || ![token isEqualToString:self.authToken]) {
            WriteHTTP(cfd, 403, "Forbidden", "invalid or missing token\n");
            close(cfd);
            return;
        }

        NSDictionary *battery = [[LSSDaemonController shared] batteryStatus];
        BOOL ok = [battery[@"ok"] boolValue];
        WriteJSON(cfd, ok ? 200 : 503, ok ? "OK" : "Service Unavailable", battery);
        close(cfd);
        return;
    }

    if ([path isEqualToString:@"/set"]) {
        NSDictionary *q = ParseQuery(query);
        NSString *lat = q[@"lat"];
        NSString *lon = q[@"lon"];
        NSString *token = q[@"token"];

        if (token == nil || ![token isEqualToString:self.authToken]) {
            WriteHTTP(cfd, 403, "Forbidden", "invalid or missing token\n");
            close(cfd);
            return;
        }

        if (lat.length == 0 || lon.length == 0) {
            WriteHTTP(cfd, 400, "Bad Request", "missing lat or lon. use /set?lat=..&lon=..\n");
            close(cfd);
            return;
        }

        NSString *line = [NSString stringWithFormat:@"received lat=%@ lon=%@", lat, lon];
        [self log:line];

        double dlat = lat.doubleValue;
        double dlon = lon.doubleValue;

        // Basic sanity clamp
        if (!(dlat >= -90.0 && dlat <= 90.0 && dlon >= -180.0 && dlon <= 180.0)) {
            WriteHTTP(cfd, 400, "Bad Request", "lat/lon out of range\n");
            close(cfd);
            return;
        }

        [self log:[NSString stringWithFormat:@"pushing location %.6f, %.6f", dlat, dlon]];
        if (self.locationSink) {
            self.locationSink(dlat, dlon);
        }

        NSString *resp = [NSString stringWithFormat:@"received lat=%@ lon=%@\n", lat, lon];
        WriteHTTP(cfd, 200, "OK", resp.UTF8String);
        close(cfd);
        return;
    }


    WriteHTTP(cfd, 404, "Not Found", "not found\n");
    close(cfd);
}

- (BOOL)startOnPort:(int)port {
    if (self.listenFD >= 0) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }
    if (listen(fd, 16) != 0) { close(fd); return NO; }

    self.listenFD = fd;
    self.port = port;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, q);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;

        int cfd = accept(self.listenFD, NULL, NULL);
        if (cfd < 0) return;

        // /friends/refresh can block tens of seconds spawning the FMF helper;
        // handle off the accept queue so it never stalls /set location pushes.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleClient:cfd];
        });
    });

    dispatch_resume(self.acceptSource);
    NSString *logLine = [NSString stringWithFormat:@"listening on http://127.0.0.1:%d", port];
    [self log:logLine];
    return YES;
}

- (void)stop {
    if (self.acceptSource) {
        dispatch_source_cancel(self.acceptSource);
        self.acceptSource = nil;
    }
    if (self.listenFD >= 0) {
        close(self.listenFD);
        self.listenFD = -1;
    }
    self.port = -1;
}

- (void)dealloc {
    [self stop];
}

@end

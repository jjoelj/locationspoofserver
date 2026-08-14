#import "LSSDaemonClient.h"

@implementation LSSDaemonClient

- (NSURL *)baseURL {
    return [NSURL URLWithString:@"http://127.0.0.1:31666"];
}

- (void)request:(NSString *)path method:(NSString *)method json:(NSDictionary *)json completion:(void (^)(BOOL ok, NSDictionary *resp))completion {
    NSURL *url = [[self baseURL] URLByAppendingPathComponent:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;

    if (json) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            completion(NO, @{@"ok": @NO, @"message": err.localizedDescription ?: @"request failed"});
            return;
        }
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            completion(NO, @{@"ok": @NO, @"message": @"bad json response"});
            return;
        }
        completion([obj[@"ok"] boolValue], obj);
    }] resume];
}

- (void)getLogs:(void (^)(BOOL ok, NSString *logs))completion {
    [self request:@"/logs" method:@"GET" json:nil completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"logs"] ?: @"");
    }];
}

- (void)getStatus:(void (^)(BOOL ok, NSDictionary *daemons))completion {
    [self request:@"/status" method:@"GET" json:nil completion:^(BOOL ok, NSDictionary *resp) {
        NSDictionary *d = [resp[@"daemons"] isKindOfClass:[NSDictionary class]] ? resp[@"daemons"] : @{};
        completion(ok, d);
    }];
}

- (void)getToken:(void (^)(BOOL ok, NSString *token, NSString *url))completion {
    [self request:@"/token" method:@"GET" json:nil completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"token"] ?: @"", resp[@"url"] ?: @"");
    }];
}

- (void)restartDaemon:(void (^)(BOOL ok, NSString *message))completion {
    [self request:@"/restart" method:@"POST" json:@{} completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"message"] ?: @"");
    }];
}

- (void)tailscaleLogin:(void (^)(BOOL ok, NSString *loginURL, NSString *message))completion {
    [self request:@"/tailscale/login" method:@"POST" json:@{} completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"loginURL"] ?: @"", resp[@"message"] ?: @"");
    }];
}

- (void)tailscaleLogout:(void (^)(BOOL ok, NSString *message))completion {
    [self request:@"/tailscale/logout" method:@"POST" json:@{} completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"message"] ?: @"");
    }];
}

- (void)regenerateToken:(void (^)(BOOL ok, NSString *message))completion {
    [self request:@"/token/regenerate" method:@"POST" json:@{} completion:^(BOOL ok, NSDictionary *resp) {
        completion(ok, resp[@"message"] ?: @"");
    }];
}

@end

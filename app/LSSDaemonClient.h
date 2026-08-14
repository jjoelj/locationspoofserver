#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSDaemonClient : NSObject

- (void)getLogs:(void (^)(BOOL ok, NSString *logs))completion;
/// Daemon name -> @(BOOL) running. Empty when the control server is unreachable.
- (void)getStatus:(void (^)(BOOL ok, NSDictionary *daemons))completion;
/// `url` is the public Funnel URL, or empty when the node isn't reachable yet.
- (void)getToken:(void (^)(BOOL ok, NSString *token, NSString *url))completion;
- (void)regenerateToken:(void (^)(BOOL ok, NSString *message))completion;
/// Asks the daemon to exit; launchd restarts it. Also drops its cached
/// Tailscale URL, which is the usual reason to want this.
- (void)restartDaemon:(void (^)(BOOL ok, NSString *message))completion;
/// Starts an interactive Tailscale login. `loginURL` is the page to open in
/// Safari, or empty when the node was already logged in. Takes a few seconds.
- (void)tailscaleLogin:(void (^)(BOOL ok, NSString *loginURL, NSString *message))completion;
/// Logs the node out of the tailnet; the public URL goes away until the next login.
- (void)tailscaleLogout:(void (^)(BOOL ok, NSString *message))completion;
@end

NS_ASSUME_NONNULL_END

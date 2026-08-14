#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSDaemonController : NSObject
+ (instancetype)shared;

@property(nonatomic, assign, readonly) int publicPort;
@property(nonatomic, copy) NSString *setEndpointToken;

- (void)startServices;

/// Public Funnel URL of this node, e.g. https://iphone.tailnet.ts.net.
/// nil when tailscaled isn't running or the node isn't logged in.
- (nullable NSString *)publicURL;

/// Start an interactive Tailscale login. Blocks until the login URL is known
/// (~seconds) and returns @{ok, loginURL} for the app to open in Safari;
/// loginURL is empty when the node was already logged in.
- (NSDictionary *)tailscaleLogin;

/// Log the node out of the tailnet. The public URL goes dark until someone
/// logs in again from the app.
- (NSDictionary *)tailscaleLogout;
- (NSDictionary *)regenerateToken;
- (NSString *)friendsJSON;
- (NSString *)friendsJSONForHandle:(nullable NSString *)handle;
- (NSString *)refreshFriendsJSONForHandle:(nullable NSString *)handle ifStarted:(BOOL *)started;
- (NSDictionary *)batteryStatus;
/// Liveness of each daemon in the package, keyed by name.
- (NSDictionary *)daemonStatus;
- (NSDictionary *)logs;

@end

NS_ASSUME_NONNULL_END

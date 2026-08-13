#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSDaemonController : NSObject
+ (instancetype)shared;

@property(nonatomic, assign, readonly) int publicPort;
@property(nonatomic, copy) NSString *setEndpointToken;

- (void)startServices;

- (NSDictionary *)applyToken:(NSString *)token;
- (NSDictionary *)regenerateToken;
- (NSString *)friendsJSON;
- (NSString *)friendsJSONForHandle:(nullable NSString *)handle;
- (NSString *)refreshFriendsJSONForHandle:(nullable NSString *)handle ifStarted:(BOOL *)started;
- (NSDictionary *)batteryStatus;
- (NSDictionary *)logs;

@end

NS_ASSUME_NONNULL_END

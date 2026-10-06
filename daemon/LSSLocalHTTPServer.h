#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LSSLogSink)(NSString *line);
typedef void (^LSSLocationSink)(CLLocation *location);

@interface LSSLocalHTTPServer : NSObject
@property(nonatomic, assign, readonly) int port;
@property(nonatomic, copy) NSString *authToken;
@property(nonatomic, copy) LSSLocationSink locationSink;

- (BOOL)startOnPort:(int)port;
- (void)stop;
@end

NS_ASSUME_NONNULL_END

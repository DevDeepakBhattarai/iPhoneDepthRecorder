#import <Foundation/Foundation.h>
@class CaptureEngine;

@interface RemoteControlServer : NSObject
@property (nonatomic, readonly) uint16_t port;
- (instancetype)initWithEngine:(CaptureEngine *)engine port:(uint16_t)port;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

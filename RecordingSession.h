#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface RecordingSession : NSObject
@property (nonatomic, readonly) NSURL *packageURL;
@property (nonatomic, readonly) uint64_t videoFrames;
@property (nonatomic, readonly) uint64_t depthFrames;
@property (nonatomic, readonly) uint64_t audioSamples;
@property (nonatomic, readonly) uint64_t droppedVideoFrames;
@property (nonatomic, readonly) uint64_t droppedDepthFrames;
@property (nonatomic, readonly, getter=isStarted) BOOL started;

- (instancetype)initWithClock:(CMClockRef)clock
                videoSettings:(NSDictionary *)videoSettings
                audioSettings:(NSDictionary *)audioSettings
                 captureInfo:(NSDictionary *)captureInfo;
- (BOOL)startWithVideoSample:(CMSampleBufferRef)videoSample error:(NSError **)error;
- (void)appendVideoSample:(CMSampleBufferRef)videoSample
                depthData:(AVDepthData *)depthData
           depthTimestamp:(CMTime)depthTimestamp
             videoDropped:(BOOL)videoDropped
             depthDropped:(BOOL)depthDropped;
- (void)appendAudioSample:(CMSampleBufferRef)audioSample;
- (void)finishWithCompletion:(void (^)(NSURL *url, NSError *error))completion;
@end

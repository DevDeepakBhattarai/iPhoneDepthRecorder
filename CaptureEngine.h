#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class CaptureEngine;

@protocol CaptureEngineDelegate <NSObject>
- (void)captureEngine:(CaptureEngine *)engine didUpdateStatus:(NSString *)status;
- (void)captureEngine:(CaptureEngine *)engine didUpdateTelemetry:(NSString *)telemetry;
- (void)captureEngine:(CaptureEngine *)engine didOutputPreviewPixelBuffer:(CVPixelBufferRef)pixelBuffer depthData:(AVDepthData *)depthData;
- (void)captureEngine:(CaptureEngine *)engine recordingDidFinishAtURL:(NSURL *)url error:(NSError *)error;
@end

@interface CaptureEngine : NSObject <AVCaptureDataOutputSynchronizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<CaptureEngineDelegate> delegate;
@property (nonatomic, strong, readonly) AVCaptureSession *session;
@property (atomic, readonly, getter=isRecording) BOOL recording;
@property (atomic, readonly, getter=isFinalizing) BOOL finalizing;
@property (atomic, copy, readonly) NSString *capabilitiesText;
@property (atomic, copy, readonly) NSString *selectedFormatSummary;
@property (atomic, readonly) CGPoint computationalFocusPoint;
@property (atomic, getter=isPreviewEnabled) BOOL previewEnabled;
@property (atomic) BOOL recordAudioEnabled;
@property (atomic, readonly, getter=isAEAFWBLocked) BOOL aeAfWbLocked;

- (void)prepareAndStart;
- (void)startRecording;
- (void)stopRecording;
- (void)setComputationalFocusPoint:(CGPoint)point;
- (void)lockAEAFWBAtPoint:(CGPoint)point completion:(void (^)(BOOL locked))completion;
- (void)unlockAEAFWB;
- (void)setCaptureOrientationName:(NSString *)orientationName;

// Live camera controls. 13/65 mm select physical RGB-only cameras; 26 mm
// restores the RGB+LiDAR capture path. Manual controls apply to the active device.
- (NSDictionary *)cameraControlSnapshot;
- (void)setExposureBias:(float)bias;
- (void)setAutoExposure;
- (void)setManualExposureISO:(float)iso shutterSeconds:(double)seconds;
- (void)setFocusLensPosition:(float)position;
- (void)setAutoFocus;
- (void)setWhiteBalanceTemperature:(float)temperature tint:(float)tint;
- (void)setAutoWhiteBalance;
- (void)setZoomFactor:(CGFloat)factor;
- (void)selectRearLensIndex:(NSInteger)index;
- (void)setTorchLevel:(float)level;
- (void)switchCameraPosition;
@end

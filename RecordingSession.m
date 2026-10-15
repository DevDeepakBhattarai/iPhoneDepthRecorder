#import "RecordingSession.h"
#import <CoreVideo/CoreVideo.h>
#import <simd/simd.h>

#pragma pack(push, 1)
typedef struct {
    char magic[4];          // DPT1
    uint32_t headerSize;
    uint64_t captureIndex;
    int64_t videoPTSValue;
    int32_t videoPTSTimescale;
    int64_t depthPTSValue;
    int32_t depthPTSTimescale;
    int64_t utcNanoseconds;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    uint32_t payloadBytes;
} DRDepthFrameHeader;
#pragma pack(pop)

@interface RecordingSession ()
@property (nonatomic, readwrite) NSURL *packageURL;
@property (nonatomic, readwrite) uint64_t videoFrames;
@property (nonatomic, readwrite) uint64_t depthFrames;
@property (nonatomic, readwrite) uint64_t audioSamples;
@property (nonatomic, readwrite) uint64_t droppedVideoFrames;
@property (nonatomic, readwrite) uint64_t droppedDepthFrames;
@property (nonatomic, readwrite, getter=isStarted) BOOL started;
@property (nonatomic) uint64_t captureFrames;
@property (nonatomic) uint64_t depthOffset;
@property (nonatomic) CMTime clockAnchorPTS;
@property (nonatomic) int64_t clockAnchorUTCNs;
@property (nonatomic) int64_t clockAnchorUncertaintyNs;
@property (nonatomic) CMTime sessionStartPTS;
@property (nonatomic) CMTime lastVideoPTS;
@property (nonatomic) CMTime lastAudioPTS;
@property (nonatomic, strong) NSDictionary *videoSettings;
@property (nonatomic, strong) NSDictionary *audioSettings;
@property (nonatomic, strong) NSDictionary *captureInfo;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) NSFileHandle *depthHandle;
@property (nonatomic, strong) NSFileHandle *framesHandle;
@property (nonatomic) BOOL calibrationWritten;
@property (nonatomic) BOOL finishing;
@end

@implementation RecordingSession

static CGAffineTransform DRDisplayTransformForOrientationName(NSString *name) {
    if ([name isEqualToString:@"portrait"]) return CGAffineTransformMakeRotation((CGFloat)M_PI_2);
    if ([name isEqualToString:@"portraitUpsideDown"]) return CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
    if ([name isEqualToString:@"landscapeLeft"]) return CGAffineTransformMakeRotation((CGFloat)M_PI);
    return CGAffineTransformIdentity;
}

static int64_t DRUnixNanosecondsNow(void) {
    return (int64_t)llround([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static BOOL DRSafeWriteData(NSFileHandle *handle, NSData *data) {
    if (!handle || !data) return NO;
    @try {
        [handle writeData:data];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void DRSafeCloseFile(NSFileHandle *handle) {
    if (!handle) return;
    @try {
        [handle synchronizeFile];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

- (instancetype)initWithClock:(CMClockRef)clock
                videoSettings:(NSDictionary *)videoSettings
                audioSettings:(NSDictionary *)audioSettings
                 captureInfo:(NSDictionary *)captureInfo {
    self = [super init];
    if (!self) return nil;

    _videoSettings = [videoSettings copy] ?: @{};
    _audioSettings = [audioSettings copy] ?: @{};
    _captureInfo = [captureInfo copy] ?: @{};
    _lastVideoPTS = kCMTimeInvalid;
    _lastAudioPTS = kCMTimeInvalid;
    if (clock) {
        CMTime bestMid = CMClockGetTime(clock);
        int64_t bestUTC = DRUnixNanosecondsNow();
        int64_t bestUncertainty = INT64_MAX;
        // Bracket the wall-clock sample with the capture clock. Repeating this and
        // keeping the narrowest bracket reduces scheduler/preemption error in the
        // absolute UTC mapping without perturbing the monotonic inter-frame timing.
        for (int attempt = 0; attempt < 8; attempt++) {
            CMTime before = CMClockGetTime(clock);
            int64_t utc = DRUnixNanosecondsNow();
            CMTime after = CMClockGetTime(clock);
            CMTime span = CMTimeSubtract(after, before);
            double spanSeconds = CMTimeGetSeconds(span);
            if (!isfinite(spanSeconds) || spanSeconds < 0) continue;
            int64_t uncertainty = (int64_t)llround(spanSeconds * 500000000.0);
            if (uncertainty < bestUncertainty) {
                bestUncertainty = uncertainty;
                bestMid = CMTimeAdd(before, CMTimeMultiplyByFloat64(span, 0.5));
                bestUTC = utc;
            }
        }
        _clockAnchorPTS = bestMid;
        _clockAnchorUTCNs = bestUTC;
        _clockAnchorUncertaintyNs = bestUncertainty == INT64_MAX ? 0 : bestUncertainty;
    } else {
        _clockAnchorPTS = kCMTimeZero;
        _clockAnchorUTCNs = DRUnixNanosecondsNow();
        _clockAnchorUncertaintyNs = 0;
    }

    NSError *error = nil;
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *recordings = [documents URLByAppendingPathComponent:@"Recordings" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:recordings withIntermediateDirectories:YES attributes:nil error:&error];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd_HHmmss_SSS'Z'";
    NSString *name = [NSString stringWithFormat:@"%@_%@.depthrec", [formatter stringFromDate:[NSDate date]], [[NSUUID UUID].UUIDString substringToIndex:8]];
    _packageURL = [recordings URLByAppendingPathComponent:name isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:_packageURL withIntermediateDirectories:YES attributes:nil error:&error];

    NSURL *depthURL = [_packageURL URLByAppendingPathComponent:@"depth.bin"];
    NSURL *framesURL = [_packageURL URLByAppendingPathComponent:@"frames.jsonl"];
    [[NSFileManager defaultManager] createFileAtPath:depthURL.path contents:nil attributes:nil];
    [[NSFileManager defaultManager] createFileAtPath:framesURL.path contents:nil attributes:nil];
    _depthHandle = [NSFileHandle fileHandleForWritingAtPath:depthURL.path];
    _framesHandle = [NSFileHandle fileHandleForWritingAtPath:framesURL.path];

    NSMutableData *depthHeader = [NSMutableData data];
    const char magic[8] = {'D','R','D','E','P','T','H','1'};
    uint32_t version = 1;
    uint32_t endian = 0x01020304;
    [depthHeader appendBytes:magic length:sizeof(magic)];
    [depthHeader appendBytes:&version length:sizeof(version)];
    [depthHeader appendBytes:&endian length:sizeof(endian)];
    if (DRSafeWriteData(_depthHandle, depthHeader)) _depthOffset = depthHeader.length;
    else _depthOffset = 0;

    return self;
}

- (int64_t)utcNanosecondsForPTS:(CMTime)pts {
    if (!CMTIME_IS_VALID(pts) || !CMTIME_IS_VALID(self.clockAnchorPTS)) return self.clockAnchorUTCNs;
    CMTime delta = CMTimeSubtract(pts, self.clockAnchorPTS);
    double seconds = CMTimeGetSeconds(delta);
    if (!isfinite(seconds)) return self.clockAnchorUTCNs;
    return self.clockAnchorUTCNs + (int64_t)llround(seconds * 1000000000.0);
}

- (BOOL)startWithVideoSample:(CMSampleBufferRef)videoSample error:(NSError **)error {
    if (self.started) return YES;
    if (!videoSample) return NO;

    NSURL *movieURL = [self.packageURL URLByAppendingPathComponent:@"master.mov"];
    [[NSFileManager defaultManager] removeItemAtURL:movieURL error:nil];
    self.writer = [[AVAssetWriter alloc] initWithURL:movieURL fileType:AVFileTypeQuickTimeMovie error:error];
    if (!self.writer) return NO;

    CMFormatDescriptionRef videoFormat = CMSampleBufferGetFormatDescription(videoSample);
    NSDictionary *videoSettings = self.videoSettings;
    if (videoSettings.count == 0) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat);
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(dimensions.width),
            AVVideoHeightKey: @(dimensions.height),
            AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @24000000 }
        };
    }

    self.videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings sourceFormatHint:videoFormat];
    self.videoInput.expectsMediaDataInRealTime = YES;
    NSString *orientationName = self.captureInfo[@"capture_interface_orientation"] ?: @"landscapeRight";
    self.videoInput.transform = DRDisplayTransformForOrientationName(orientationName);
    if (![self.writer canAddInput:self.videoInput]) {
        if (error) *error = [NSError errorWithDomain:@"DepthRecorder" code:1001 userInfo:@{NSLocalizedDescriptionKey:@"Cannot add video input to AVAssetWriter"}];
        return NO;
    }
    [self.writer addInput:self.videoInput];

    if (self.audioSettings.count > 0) {
        self.audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
        self.audioInput.expectsMediaDataInRealTime = YES;
        if ([self.writer canAddInput:self.audioInput]) [self.writer addInput:self.audioInput];
        else self.audioInput = nil;
    }

    self.sessionStartPTS = CMSampleBufferGetPresentationTimeStamp(videoSample);
    if (![self.writer startWriting]) {
        if (error) *error = self.writer.error;
        return NO;
    }
    [self.writer startSessionAtSourceTime:self.sessionStartPTS];
    self.started = YES;
    return YES;
}

- (void)writeCalibrationIfNeeded:(AVDepthData *)depthData {
    if (self.calibrationWritten || !depthData.cameraCalibrationData) return;
    AVCameraCalibrationData *cal = depthData.cameraCalibrationData;
    matrix_float3x3 i = cal.intrinsicMatrix;
    matrix_float4x3 e = cal.extrinsicMatrix;
    CGSize r = cal.intrinsicMatrixReferenceDimensions;
    CGPoint c = cal.lensDistortionCenter;
    NSDictionary *json = @{
        @"matrix_storage": @"SIMD column-major",
        @"intrinsic_matrix_3x3": @[
            @(i.columns[0][0]), @(i.columns[0][1]), @(i.columns[0][2]),
            @(i.columns[1][0]), @(i.columns[1][1]), @(i.columns[1][2]),
            @(i.columns[2][0]), @(i.columns[2][1]), @(i.columns[2][2])
        ],
        @"extrinsic_matrix_4x3": @[
            @(e.columns[0][0]), @(e.columns[0][1]), @(e.columns[0][2]),
            @(e.columns[1][0]), @(e.columns[1][1]), @(e.columns[1][2]),
            @(e.columns[2][0]), @(e.columns[2][1]), @(e.columns[2][2]),
            @(e.columns[3][0]), @(e.columns[3][1]), @(e.columns[3][2])
        ],
        @"intrinsic_reference_width": @(r.width),
        @"intrinsic_reference_height": @(r.height),
        @"pixel_size_mm": @(cal.pixelSize),
        @"lens_distortion_center_x": @(c.x),
        @"lens_distortion_center_y": @(c.y)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[self.packageURL URLByAppendingPathComponent:@"calibration.json"] atomically:YES];
    self.calibrationWritten = YES;
}

- (void)appendVideoSample:(CMSampleBufferRef)videoSample
                depthData:(AVDepthData *)depthData
           depthTimestamp:(CMTime)depthTimestamp
             videoDropped:(BOOL)videoDropped
             depthDropped:(BOOL)depthDropped {
    uint64_t captureIndex = self.captureFrames++;
    CMTime videoPTS = videoSample ? CMSampleBufferGetPresentationTimeStamp(videoSample) : kCMTimeInvalid;
    int64_t utcNS = [self utcNanosecondsForPTS:videoPTS];

    BOOL videoAppended = NO;
    if (videoDropped || !videoSample || !CMSampleBufferIsValid(videoSample)) {
        self.droppedVideoFrames++;
    } else if (self.started && self.writer.status == AVAssetWriterStatusWriting && self.videoInput.readyForMoreMediaData) {
        videoAppended = [self.videoInput appendSampleBuffer:videoSample];
        if (videoAppended) {
            self.videoFrames++;
            self.lastVideoPTS = videoPTS;
        }
        else self.droppedVideoFrames++;
    } else {
        self.droppedVideoFrames++;
    }

    uint64_t frameOffset = 0;
    uint32_t payloadLength = 0;
    uint32_t depthWidth = 0, depthHeight = 0, depthPixelFormat = 0;
    BOOL depthExpected = [self.captureInfo[@"depth_available"] boolValue];
    BOOL effectiveDepthDropped = depthExpected && (depthDropped || !depthData);

    if (!depthExpected) {
        // RGB-only physical lens mode: depth is intentionally disabled, not dropped.
    } else if (effectiveDepthDropped) {
        self.droppedDepthFrames++;
    } else {
        AVDepthData *converted = nil;
        @try {
            converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat16
                ? depthData
                : [depthData depthDataByConvertingToDepthDataType:kCVPixelFormatType_DepthFloat16];
        } @catch (__unused NSException *exception) {
            converted = nil;
        }
        if (converted) [self writeCalibrationIfNeeded:converted];
        CVPixelBufferRef map = converted.depthDataMap;
        BOOL wroteDepth = NO;
        if (map && CVPixelBufferLockBaseAddress(map, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            size_t width = CVPixelBufferGetWidth(map);
            size_t height = CVPixelBufferGetHeight(map);
            size_t sourceBPR = CVPixelBufferGetBytesPerRow(map);
            size_t packedBPR = width * sizeof(uint16_t);
            const uint8_t *source = CVPixelBufferGetBaseAddress(map);
            if (source && width > 0 && height > 0 && sourceBPR >= packedBPR &&
                packedBPR <= UINT32_MAX && height <= UINT32_MAX && packedBPR <= SIZE_MAX / height) {
                NSMutableData *payload = [NSMutableData dataWithLength:packedBPR * height];
                uint8_t *dest = payload.mutableBytes;
                if (dest) {
                    for (size_t y = 0; y < height; y++) {
                        memcpy(dest + y * packedBPR, source + y * sourceBPR, packedBPR);
                    }

                    DRDepthFrameHeader h = {0};
                    h.magic[0]='D'; h.magic[1]='P'; h.magic[2]='T'; h.magic[3]='1';
                    h.headerSize = (uint32_t)sizeof(h);
                    h.captureIndex = captureIndex;
                    h.videoPTSValue = videoPTS.value;
                    h.videoPTSTimescale = videoPTS.timescale;
                    h.depthPTSValue = depthTimestamp.value;
                    h.depthPTSTimescale = depthTimestamp.timescale;
                    h.utcNanoseconds = utcNS;
                    h.width = (uint32_t)width;
                    h.height = (uint32_t)height;
                    h.bytesPerRow = (uint32_t)packedBPR;
                    h.pixelFormat = (uint32_t)kCVPixelFormatType_DepthFloat16;
                    h.payloadBytes = (uint32_t)payload.length;
                    NSData *headerData = [NSData dataWithBytes:&h length:sizeof(h)];
                    uint64_t candidateOffset = self.depthOffset;
                    if (DRSafeWriteData(self.depthHandle, headerData) && DRSafeWriteData(self.depthHandle, payload)) {
                        frameOffset = candidateOffset;
                        self.depthOffset += headerData.length + payload.length;
                        payloadLength = (uint32_t)payload.length;
                        depthWidth = (uint32_t)width;
                        depthHeight = (uint32_t)height;
                        depthPixelFormat = (uint32_t)kCVPixelFormatType_DepthFloat16;
                        self.depthFrames++;
                        wroteDepth = YES;
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(map, kCVPixelBufferLock_ReadOnly);
        }
        if (!wroteDepth) self.droppedDepthFrames++;
    }

    NSString *line = [NSString stringWithFormat:
        @"{\"capture_index\":%llu,\"video_index\":%lld,\"video_pts_value\":%lld,\"video_pts_timescale\":%d,\"depth_pts_value\":%lld,\"depth_pts_timescale\":%d,\"utc_ns\":%lld,\"video_appended\":%@,\"video_dropped\":%@,\"depth_dropped\":%@,\"depth_offset\":%llu,\"depth_payload_bytes\":%u,\"depth_width\":%u,\"depth_height\":%u,\"depth_pixel_format\":%u}\n",
        (unsigned long long)captureIndex,
        videoAppended ? (long long)(self.videoFrames - 1) : -1LL,
        (long long)videoPTS.value, (int)videoPTS.timescale,
        (long long)depthTimestamp.value, (int)depthTimestamp.timescale,
        (long long)utcNS,
        videoAppended ? @"true" : @"false",
        videoDropped ? @"true" : @"false",
        effectiveDepthDropped ? @"true" : @"false",
        (unsigned long long)frameOffset, payloadLength, depthWidth, depthHeight, depthPixelFormat];
    DRSafeWriteData(self.framesHandle, [line dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)appendAudioSample:(CMSampleBufferRef)audioSample {
    if (!self.started || !audioSample || !CMSampleBufferIsValid(audioSample) || !self.audioInput) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(audioSample);
    if (CMTIME_COMPARE_INLINE(pts, <, self.sessionStartPTS)) return;
    if (self.writer.status == AVAssetWriterStatusWriting && self.audioInput.readyForMoreMediaData) {
        if ([self.audioInput appendSampleBuffer:audioSample]) {
            self.audioSamples++;
            self.lastAudioPTS = pts;
        }
    }
}

- (void)writeManifestWithWriterStatus:(AVAssetWriterStatus)status error:(NSError *)writerError {
    int64_t endUTC = DRUnixNanosecondsNow();
    NSMutableDictionary *manifest = [NSMutableDictionary dictionaryWithDictionary:self.captureInfo ?: @{}];
    manifest[@"format_version"] = @1;
    manifest[@"package_type"] = @"DepthRecorder RGB-D recording";
    manifest[@"depth_storage"] = @"Float16 meters; row-packed; depth.bin DPT1 records";
    manifest[@"timebase"] = @"AVCaptureSession synchronizationClock mapped to Unix UTC nanoseconds";
    manifest[@"clock_anchor_pts_value"] = @(self.clockAnchorPTS.value);
    manifest[@"clock_anchor_pts_timescale"] = @(self.clockAnchorPTS.timescale);
    manifest[@"clock_anchor_utc_ns"] = @(self.clockAnchorUTCNs);
    manifest[@"clock_anchor_uncertainty_ns"] = @(self.clockAnchorUncertaintyNs);
    manifest[@"finish_wall_utc_ns"] = @(endUTC);
    manifest[@"session_start_pts_value"] = @(self.sessionStartPTS.value);
    manifest[@"session_start_pts_timescale"] = @(self.sessionStartPTS.timescale);
    manifest[@"capture_callbacks"] = @(self.captureFrames);
    manifest[@"video_frames_appended"] = @(self.videoFrames);
    manifest[@"depth_frames_written"] = @(self.depthFrames);
    manifest[@"audio_samples_appended"] = @(self.audioSamples);
    manifest[@"dropped_video_frames"] = @(self.droppedVideoFrames);
    manifest[@"dropped_depth_frames"] = @(self.droppedDepthFrames);
    manifest[@"asset_writer_status"] = @(status);
    if (writerError) manifest[@"asset_writer_error"] = writerError.localizedDescription ?: @"unknown";
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[self.packageURL URLByAppendingPathComponent:@"manifest.json"] atomically:YES];
}

- (void)finishWithCompletion:(void (^)(NSURL *url, NSError *error))completion {
    if (self.finishing) return;
    self.finishing = YES;

    if (self.depthHandle) {
        DRSafeCloseFile(self.depthHandle);
        self.depthHandle = nil;
    }
    if (self.framesHandle) {
        DRSafeCloseFile(self.framesHandle);
        self.framesHandle = nil;
    }

    if (!self.started || !self.writer) {
        [self writeManifestWithWriterStatus:AVAssetWriterStatusUnknown error:nil];
        if (completion) completion(self.packageURL, nil);
        return;
    }

    AVAssetWriterStatus status = self.writer.status;
    if (status != AVAssetWriterStatusWriting) {
        NSError *error = self.writer.error;
        [self writeManifestWithWriterStatus:status error:error];
        if (completion) completion(self.packageURL, error);
        return;
    }

    [self.videoInput markAsFinished];
    if (self.audioInput) [self.audioInput markAsFinished];

    CMTime endPTS = self.lastVideoPTS;
    if (CMTIME_IS_VALID(self.lastAudioPTS) &&
        (!CMTIME_IS_VALID(endPTS) || CMTIME_COMPARE_INLINE(self.lastAudioPTS, >, endPTS))) {
        endPTS = self.lastAudioPTS;
    }
    if (CMTIME_IS_VALID(endPTS) && CMTIME_COMPARE_INLINE(endPTS, >=, self.sessionStartPTS)) {
        [self.writer endSessionAtSourceTime:endPTS];
    }

    // Capture self strongly until AVAssetWriter has completed. CaptureEngine also
    // keeps a finalizingRecorder reference, so neither the writer nor its metadata
    // sidecars can disappear while the asynchronous finish is in flight.
    RecordingSession *strongSelf = self;
    [self.writer finishWritingWithCompletionHandler:^{
        NSError *error = strongSelf.writer.error;
        AVAssetWriterStatus finalStatus = strongSelf.writer.status;
        [strongSelf writeManifestWithWriterStatus:finalStatus error:error];
        if (completion) completion(strongSelf.packageURL, error);
    }];
}

@end

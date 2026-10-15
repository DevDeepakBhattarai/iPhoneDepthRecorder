#import "CaptureEngine.h"
#import "RecordingSession.h"
#import <CoreVideo/CoreVideo.h>

@interface CaptureEngine ()
@property (nonatomic, strong, readwrite) AVCaptureSession *session;
@property (atomic, readwrite, getter=isRecording) BOOL recording;
@property (atomic, readwrite, getter=isFinalizing) BOOL finalizing;
@property (atomic) BOOL reconfiguring;
@property (atomic, strong) NSDictionary *cachedControlSnapshot;
@property (atomic, copy, readwrite) NSString *capabilitiesText;
@property (atomic, copy, readwrite) NSString *selectedFormatSummary;
@property (atomic, readwrite) CGPoint computationalFocusPoint;
@property (nonatomic) CGPoint focusPointStorage;
@property (atomic, readwrite, getter=isAEAFWBLocked) BOOL aeAfWbLocked;
@property (nonatomic, copy) NSString *captureOrientationName;
@property (nonatomic, strong) AVCaptureDevice *camera;
@property (nonatomic) AVCaptureDevicePosition requestedPosition;
@property (nonatomic) NSInteger requestedRearLensIndex; // 0=13mm, 1=26mm LiDAR, 2=65mm
@property (nonatomic) NSInteger activeRearLensIndex;
@property (nonatomic) BOOL microphonePermissionGranted;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureDepthDataOutput *depthOutput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) AVCaptureDataOutputSynchronizer *synchronizer;
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t captureQueue;
@property (nonatomic, strong) NSDictionary *recommendedVideoSettings;
@property (nonatomic, strong) NSDictionary *recommendedAudioSettings;
@property (nonatomic, strong) NSDictionary *captureInfo;
@property (nonatomic, strong) RecordingSession *recorder;
@property (nonatomic, strong) RecordingSession *finalizingRecorder;
@property (nonatomic) uint64_t telemetryCounter;
@property (nonatomic) uint64_t previewCounter;
@end

@implementation CaptureEngine

static NSString *DRFourCC(OSType code) {
    char s[5];
    s[0] = (char)((code >> 24) & 0xff);
    s[1] = (char)((code >> 16) & 0xff);
    s[2] = (char)((code >> 8) & 0xff);
    s[3] = (char)(code & 0xff);
    s[4] = 0;
    for (int i = 0; i < 4; i++) if (s[i] < 32 || s[i] > 126) s[i] = '?';
    return [NSString stringWithUTF8String:s];
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _session = [[AVCaptureSession alloc] init];
    _sessionQueue = dispatch_queue_create("com.deepak.depthrecorder.session", DISPATCH_QUEUE_SERIAL);
    _captureQueue = dispatch_queue_create("com.deepak.depthrecorder.capture", DISPATCH_QUEUE_SERIAL);
    _focusPointStorage = CGPointMake(0.5, 0.5);
    _captureOrientationName = @"portrait";
    _previewEnabled = YES;
    _recordAudioEnabled = YES;
    _requestedPosition = AVCaptureDevicePositionBack;
    _requestedRearLensIndex = 1;
    _activeRearLensIndex = 1;
    _aeAfWbLocked = NO;
    _recording = NO;
    _finalizing = NO;
    _reconfiguring = NO;
    _cachedControlSnapshot = @{
        @"capture_rgb_width": @0, @"capture_rgb_height": @0,
        @"camera_position": @(AVCaptureDevicePositionBack), @"camera_device_type": @"",
        @"camera_switch_factors": @[], @"selected_rear_lens_index": @1, @"capture_depth_available": @YES, @"dof_available": @YES,
        @"control_iso": @100, @"control_iso_min": @25, @"control_iso_max": @2000,
        @"control_shutter_seconds": @(1.0/60.0), @"control_shutter_min_seconds": @(1.0/10000.0), @"control_shutter_max_seconds": @(1.0/30.0),
        @"control_exposure_bias": @0, @"control_exposure_bias_min": @-2, @"control_exposure_bias_max": @2, @"control_exposure_manual": @NO,
        @"control_focus_position": @0.5, @"control_focus_manual": @NO, @"control_ae_af_wb_locked": @NO,
        @"control_white_balance_temperature": @5000, @"control_white_balance_tint": @0, @"control_white_balance_locked": @NO,
        @"control_zoom": @1, @"control_zoom_min": @1, @"control_zoom_max": @1,
        @"control_torch_available": @NO, @"control_torch_level": @0
    };
    return self;
}

- (void)sendStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate captureEngine:self didUpdateStatus:status];
    });
}

- (void)sendTelemetry:(NSString *)telemetry {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate captureEngine:self didUpdateTelemetry:telemetry];
    });
}

- (void)prepareAndStart {
    dispatch_group_t group = dispatch_group_create();
    __block BOOL cameraAllowed = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized;
    __block BOOL micAllowed = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;

    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            cameraAllowed = granted;
            dispatch_group_leave(group);
        }];
    }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
        dispatch_group_enter(group);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            micAllowed = granted;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, self.sessionQueue, ^{
        if (!cameraAllowed) {
            [self sendStatus:@"Camera permission is required."];
            return;
        }
        [self configureSessionWithMicrophone:micAllowed];
    });
}

- (AVCaptureDeviceFormat *)bestVideoFormatForDevice:(AVCaptureDevice *)device chosenDepthFormat:(AVCaptureDeviceFormat **)chosenDepth targetFPS:(double *)targetFPS {
    AVCaptureDeviceFormat *bestVideo = nil;
    AVCaptureDeviceFormat *bestDepth = nil;
    double bestScore = -1.0;
    double bestFPS = 0.0;

    for (AVCaptureDeviceFormat *format in device.formats) {
        if (format.supportedDepthDataFormats.count == 0) continue;
        CMVideoDimensions vd = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        double maxFPS = 0.0;
        BOOL supports30 = NO;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            maxFPS = MAX(maxFPS, range.maxFrameRate);
            if (range.minFrameRate <= 30.0 && range.maxFrameRate >= 30.0) supports30 = YES;
        }
        if (maxFPS < 24.0) continue;

        AVCaptureDeviceFormat *candidateDepth = nil;
        double depthScore = -1.0;
        for (AVCaptureDeviceFormat *df in format.supportedDepthDataFormats) {
            CMVideoDimensions dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription);
            OSType subtype = CMFormatDescriptionGetMediaSubType(df.formatDescription);
            double score = (double)dd.width * (double)dd.height;
            if (subtype == kCVPixelFormatType_DepthFloat16) score += 1000000000.0;
            else if (subtype == kCVPixelFormatType_DepthFloat32) score += 900000000.0;
            if (score > depthScore) { depthScore = score; candidateDepth = df; }
        }
        if (!candidateDepth) continue;

        // Prefer standard 4K UHD 16:9 at 30 fps for video framing. The full
        // 4032x3024 sensor mode remains visible in diagnostics but no longer wins
        // merely because it has more pixels. This device exposes 3840x2160 with
        // synchronized 320x180 LiDAR, which matches normal camera/OBS framing.
        double videoArea = (double)vd.width * (double)vd.height;
        double aspect = vd.height > 0 ? (double)vd.width / (double)vd.height : 0.0;
        BOOL is169 = fabs(aspect - (16.0 / 9.0)) < 0.03;
        BOOL isUHD = vd.width == 3840 && vd.height == 2160;
        BOOL isFullSensor = vd.width == 4032 && vd.height == 3024;
        BOOL preferFullSensor = [[NSUserDefaults standardUserDefaults] boolForKey:@"DRPreferFullSensor"];
        double score = videoArea;
        if (supports30) score += 10000000000.0;
        if (preferFullSensor) {
            if (isFullSensor) score += 60000000000.0;
        } else {
            if (is169) score += 20000000000.0;
            if (isUHD) score += 30000000000.0;
        }
        if (score > bestScore) {
            bestScore = score;
            bestVideo = format;
            bestDepth = candidateDepth;
            bestFPS = supports30 ? 30.0 : MIN(30.0, maxFPS);
        }
    }

    if (chosenDepth) *chosenDepth = bestDepth;
    if (targetFPS) *targetFPS = bestFPS;
    return bestVideo;
}

- (AVCaptureDeviceFormat *)bestVideoOnlyFormatForDevice:(AVCaptureDevice *)device targetFPS:(double *)targetFPS {
    AVCaptureDeviceFormat *best = nil;
    double bestScore = -1.0, bestFPS = 0.0;
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        double maxFPS = 0.0; BOOL supports30 = NO;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            maxFPS = MAX(maxFPS, range.maxFrameRate);
            if (range.minFrameRate <= 30.0 && range.maxFrameRate >= 30.0) supports30 = YES;
        }
        if (maxFPS < 24.0 || d.width < 1280 || d.height < 720) continue;
        double aspect = d.height > 0 ? (double)d.width / (double)d.height : 0.0;
        BOOL is169 = fabs(aspect - (16.0/9.0)) < 0.03;
        BOOL isUHD = d.width == 3840 && d.height == 2160;
        BOOL is1080 = d.width == 1920 && d.height == 1080;
        double score = (double)d.width * (double)d.height;
        if (supports30) score += 10000000000.0;
        if (is169) score += 20000000000.0;
        if (isUHD) score += 50000000000.0;
        else if (is1080) score += 10000000000.0;
        if (score > bestScore) { bestScore = score; best = format; bestFPS = supports30 ? 30.0 : MIN(30.0, maxFPS); }
    }
    if (targetFPS) *targetFPS = bestFPS;
    return best;
}

- (NSString *)capabilityReportForDevice:(AVCaptureDevice *)device selectedVideo:(AVCaptureDeviceFormat *)selectedVideo selectedDepth:(AVCaptureDeviceFormat *)selectedDepth targetFPS:(double)fps {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"Device: %@\nType: %@\nUnique ID: %@\n\n", device.localizedName, device.deviceType, device.uniqueID];
    NSUInteger index = 0;
    for (AVCaptureDeviceFormat *format in device.formats) {
        if (format.supportedDepthDataFormats.count == 0) continue;
        CMVideoDimensions vd = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        OSType vs = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        double maxFPS = 0.0;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) maxFPS = MAX(maxFPS, range.maxFrameRate);
        [report appendFormat:@"[%lu] RGB %dx%d %@ max %.2f fps | depths: ", (unsigned long)index++, vd.width, vd.height, DRFourCC(vs), maxFPS];
        for (AVCaptureDeviceFormat *df in format.supportedDepthDataFormats) {
            CMVideoDimensions dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription);
            [report appendFormat:@"%dx%d %@; ", dd.width, dd.height, DRFourCC(CMFormatDescriptionGetMediaSubType(df.formatDescription))];
        }
        [report appendString:@"\n"];
    }
    if (selectedVideo && selectedDepth) {
        CMVideoDimensions vd = CMVideoFormatDescriptionGetDimensions(selectedVideo.formatDescription);
        CMVideoDimensions dd = CMVideoFormatDescriptionGetDimensions(selectedDepth.formatDescription);
        [report appendFormat:@"\nSELECTED: RGB %dx%d %@ @ %.2f fps + DEPTH %dx%d %@\n", vd.width, vd.height, DRFourCC(CMFormatDescriptionGetMediaSubType(selectedVideo.formatDescription)), fps, dd.width, dd.height, DRFourCC(CMFormatDescriptionGetMediaSubType(selectedDepth.formatDescription))];
    }
    return report;
}

- (AVCaptureDevice *)bestDepthCameraForPosition:(AVCaptureDevicePosition)position videoFormat:(AVCaptureDeviceFormat **)videoOut depthFormat:(AVCaptureDeviceFormat **)depthOut fps:(double *)fpsOut {
    AVCaptureDeviceType type = nil;
    BOOL requireDepth = NO;
    if (position == AVCaptureDevicePositionFront) {
        type = AVCaptureDeviceTypeBuiltInTrueDepthCamera; requireDepth = YES;
    } else if (self.requestedRearLensIndex == 0) {
        type = AVCaptureDeviceTypeBuiltInUltraWideCamera;
    } else if (self.requestedRearLensIndex == 2) {
        type = AVCaptureDeviceTypeBuiltInTelephotoCamera;
    } else {
        type = AVCaptureDeviceTypeBuiltInLiDARDepthCamera; requireDepth = YES;
    }

    AVCaptureDeviceDiscoverySession *d = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[type] mediaType:AVMediaTypeVideo position:position];
    for (AVCaptureDevice *candidate in d.devices) {
        AVCaptureDeviceFormat *depth = nil; double fps = 0.0;
        AVCaptureDeviceFormat *video = requireDepth
            ? [self bestVideoFormatForDevice:candidate chosenDepthFormat:&depth targetFPS:&fps]
            : [self bestVideoOnlyFormatForDevice:candidate targetFPS:&fps];
        if (video && (!requireDepth || depth)) {
            if (videoOut) *videoOut = video;
            if (depthOut) *depthOut = depth;
            if (fpsOut) *fpsOut = fps;
            return candidate;
        }
    }
    return nil;
}


- (void)configureSessionWithMicrophone:(BOOL)micAllowed {
    self.reconfiguring = YES;
    self.microphonePermissionGranted = micAllowed;
    AVCaptureDevicePosition position = self.requestedPosition;
    [self sendStatus:position == AVCaptureDevicePositionFront ? @"Configuring TrueDepth camera..." : [NSString stringWithFormat:@"Configuring %ldmm rear camera...", (long)(self.requestedRearLensIndex == 0 ? 13 : (self.requestedRearLensIndex == 2 ? 65 : 26))]];

    // Quiesce callbacks from the previous graph before outputs are removed. This
    // prevents a late synchronizer callback from dereferencing outputs that are
    // already being replaced during a front/rear camera switch.
    AVCaptureDataOutputSynchronizer *oldSynchronizer = self.synchronizer;
    if (oldSynchronizer) [oldSynchronizer setDelegate:nil queue:NULL];
    if (self.videoOutput) [self.videoOutput setSampleBufferDelegate:nil queue:NULL];
    if (self.audioOutput) [self.audioOutput setSampleBufferDelegate:nil queue:NULL];
    dispatch_sync(self.captureQueue, ^{});

    AVCaptureDeviceFormat *videoFormat = nil, *depthFormat = nil; double fps = 0.0;
    AVCaptureDevice *camera = [self bestDepthCameraForPosition:position videoFormat:&videoFormat depthFormat:&depthFormat fps:&fps];
    if (!camera || !videoFormat) {
        self.reconfiguring = NO;
        [self sendStatus:position == AVCaptureDevicePositionFront ? @"Front TrueDepth camera is not available." : @"Requested rear camera is not available."];
        return;
    }
    BOOL depthAvailable = depthFormat != nil;
    self.camera = camera;

    NSError *error = nil;
    [self.session beginConfiguration];
    for (AVCaptureInput *input in [self.session.inputs copy]) [self.session removeInput:input];
    for (AVCaptureOutput *output in [self.session.outputs copy]) [self.session removeOutput:output];
    self.synchronizer = nil; self.videoOutput = nil; self.depthOutput = nil; self.audioOutput = nil;
    if ([self.session canSetSessionPreset:AVCaptureSessionPresetInputPriority]) self.session.sessionPreset = AVCaptureSessionPresetInputPriority;

    AVCaptureDeviceInput *cameraInput = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
    if (!cameraInput || ![self.session canAddInput:cameraInput]) {
        [self.session commitConfiguration];
        self.reconfiguring = NO;
        [self sendStatus:[NSString stringWithFormat:@"Camera input failed: %@", error.localizedDescription ?: @"unknown"]];
        return;
    }
    [self.session addInput:cameraInput];

    if ([camera lockForConfiguration:&error]) {
        @try {
            camera.activeFormat = videoFormat;
            if (depthAvailable) camera.activeDepthDataFormat = depthFormat;
            if (fps > 0.0 && isfinite(fps)) {
                CMTime frameDuration = CMTimeMake(1000, (int32_t)llround(fps * 1000.0));
                BOOL supported = NO;
                for (AVFrameRateRange *range in videoFormat.videoSupportedFrameRateRanges) {
                    if (range.minFrameRate <= fps && range.maxFrameRate >= fps) { supported = YES; break; }
                }
                if (supported) {
                    camera.activeVideoMinFrameDuration = frameDuration;
                    camera.activeVideoMaxFrameDuration = frameDuration;
                }
            }
            if (position == AVCaptureDevicePositionBack) {
                CGFloat minZoom = MAX(0.1, camera.minAvailableVideoZoomFactor);
                camera.videoZoomFactor = MIN(camera.maxAvailableVideoZoomFactor, MAX(minZoom, 1.0));
                self.activeRearLensIndex = self.requestedRearLensIndex;
            }
        } @catch (NSException *exception) {
            [camera unlockForConfiguration];
            [self.session commitConfiguration];
            self.reconfiguring = NO;
            [self sendStatus:[NSString stringWithFormat:@"Could not configure camera safely: %@", exception.reason ?: exception.name]];
            return;
        }
        [camera unlockForConfiguration];
    } else {
        [self.session commitConfiguration];
        self.reconfiguring = NO;
        [self sendStatus:[NSString stringWithFormat:@"Could not configure camera format: %@", error.localizedDescription ?: @"unknown"]];
        return;
    }

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
    self.videoOutput.alwaysDiscardsLateVideoFrames = NO;
    if (![self.session canAddOutput:self.videoOutput]) {
        [self.session commitConfiguration];
        self.reconfiguring = NO;
        [self sendStatus:@"Cannot add RGB video output."];
        return;
    }
    [self.session addOutput:self.videoOutput];

    self.depthOutput = nil;
    if (depthAvailable) {
        self.depthOutput = [[AVCaptureDepthDataOutput alloc] init];
        self.depthOutput.filteringEnabled = YES;
        self.depthOutput.alwaysDiscardsLateDepthData = NO;
        if (![self.session canAddOutput:self.depthOutput]) {
            [self.session commitConfiguration];
            self.reconfiguring = NO;
            [self sendStatus:@"Cannot add LiDAR depth output."];
            return;
        }
        [self.session addOutput:self.depthOutput];
    }

    self.audioOutput = nil;
    if (micAllowed) {
        AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (mic) {
            AVCaptureDeviceInput *micInput = [AVCaptureDeviceInput deviceInputWithDevice:mic error:nil];
            AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
            if (micInput && [self.session canAddInput:micInput] && [self.session canAddOutput:audioOutput]) {
                [self.session addInput:micInput];
                [self.session addOutput:audioOutput];
                [audioOutput setSampleBufferDelegate:self queue:self.captureQueue];
                self.audioOutput = audioOutput;
            }
        }
    }

    [self.session commitConfiguration];

    if (self.depthOutput) {
        NSArray *outputs = @[self.videoOutput, self.depthOutput];
        self.synchronizer = [[AVCaptureDataOutputSynchronizer alloc] initWithDataOutputs:outputs];
        [self.synchronizer setDelegate:self queue:self.captureQueue];
    } else {
        self.synchronizer = nil;
        [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    }

    NSDictionary *videoSettings = nil;
    if ([self.videoOutput respondsToSelector:@selector(recommendedVideoSettingsForVideoCodecType:assetWriterOutputFileType:)]) {
        videoSettings = [self.videoOutput recommendedVideoSettingsForVideoCodecType:AVVideoCodecTypeHEVC assetWriterOutputFileType:AVFileTypeQuickTimeMovie];
    }
    if (!videoSettings) videoSettings = [self.videoOutput recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie];
    self.recommendedVideoSettings = videoSettings ?: @{};
    self.recommendedAudioSettings = self.audioOutput ? ([self.audioOutput recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] ?: @{}) : @{};

    CMVideoDimensions vd = CMVideoFormatDescriptionGetDimensions(videoFormat.formatDescription);
    CMVideoDimensions dd = {0,0};
    if (depthFormat) dd = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription);
    NSMutableDictionary *info = [@{
        @"camera_name": camera.localizedName ?: @"unknown",
        @"camera_device_type": camera.deviceType ?: @"unknown",
        @"camera_unique_id": camera.uniqueID ?: @"unknown",
        @"camera_position": @(camera.position),
        @"rear_lens_index": @(camera.position == AVCaptureDevicePositionBack ? self.activeRearLensIndex : -1),
        @"rear_lens_equivalent_mm": @(camera.position == AVCaptureDevicePositionBack ? (self.activeRearLensIndex == 0 ? 13 : (self.activeRearLensIndex == 2 ? 65 : 26)) : 0),
        @"rgb_width": @(vd.width),
        @"rgb_height": @(vd.height),
        @"rgb_pixel_format_fourcc": DRFourCC(CMFormatDescriptionGetMediaSubType(videoFormat.formatDescription)),
        @"depth_width": @(dd.width),
        @"depth_height": @(dd.height),
        @"depth_pixel_format_fourcc": depthFormat ? DRFourCC(CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription)) : @"none",
        @"target_fps": @(fps),
        @"depth_filtering": @(depthAvailable),
        @"depth_available": @(depthAvailable),
        @"dof_available": @(depthAvailable),
        @"microphone_enabled": @(self.audioOutput != nil)
    } mutableCopy];
    self.captureInfo = [info copy];

    NSInteger mm = camera.position == AVCaptureDevicePositionBack ? (self.activeRearLensIndex == 0 ? 13 : (self.activeRearLensIndex == 2 ? 65 : 26)) : 0;
    self.selectedFormatSummary = depthAvailable
        ? [NSString stringWithFormat:@"%dx%d | %.0f fps | %ldmm | depth %dx%d | UTC", vd.width, vd.height, fps, (long)mm, dd.width, dd.height]
        : [NSString stringWithFormat:@"%dx%d | %.0f fps | %ldmm | RGB only | UTC", vd.width, vd.height, fps, (long)mm];

    self.capabilitiesText = [self capabilityReportForDevice:camera selectedVideo:videoFormat selectedDepth:depthFormat targetFPS:fps];
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    [self.capabilitiesText writeToURL:[documents URLByAppendingPathComponent:@"last_camera_capabilities.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    @try {
        [self.session startRunning];
    } @catch (NSException *exception) {
        self.reconfiguring = NO;
        [self sendStatus:[NSString stringWithFormat:@"Camera start failed safely: %@", exception.reason ?: exception.name]];
        return;
    }
    if (!self.session.isRunning) {
        self.reconfiguring = NO;
        [self sendStatus:@"Camera session did not start."];
        return;
    }
    self.reconfiguring = NO;
    [self updateRearLensMetadataOnSessionQueue];
    [self refreshControlSnapshotOnSessionQueue];
    if (depthAvailable) {
        [self sendStatus:[NSString stringWithFormat:@"Ready - RGB %dx%d + LiDAR %dx%d @ %.0f fps%@", vd.width, vd.height, dd.width, dd.height, fps, self.audioOutput ? @" + audio" : @" (no mic)"]];
        [self sendTelemetry:@"UTC frame mapping armed. Depth filtering ON."];
    } else {
        [self sendStatus:[NSString stringWithFormat:@"Ready - RGB %dx%d @ %.0f fps ? depth/DOF off%@", vd.width, vd.height, fps, self.audioOutput ? @" + audio" : @" (no mic)"]];
        [self sendTelemetry:@"RGB-only physical lens mode. LiDAR and DOF are disabled."];
    }
}

- (CGPoint)computationalFocusPoint {
    @synchronized (self) { return _focusPointStorage; }
}

- (void)setComputationalFocusPoint:(CGPoint)point {
    point.x = MIN(1.0, MAX(0.0, point.x));
    point.y = MIN(1.0, MAX(0.0, point.y));
    @synchronized (self) { _focusPointStorage = point; }

    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *camera = self.camera;
        if (!camera) return;
        NSError *error = nil;
        if (![camera lockForConfiguration:&error]) return;
        @try {
            if (camera.isFocusPointOfInterestSupported) camera.focusPointOfInterest = point;
            if (camera.isExposurePointOfInterestSupported) camera.exposurePointOfInterest = point;
            if ([camera isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                camera.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            } else if ([camera isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
                camera.focusMode = AVCaptureFocusModeAutoFocus;
            }
            if ([camera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                camera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            } else if ([camera isExposureModeSupported:AVCaptureExposureModeAutoExpose]) {
                camera.exposureMode = AVCaptureExposureModeAutoExpose;
            }
            if ([camera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                camera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
            } else if ([camera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeAutoWhiteBalance]) {
                camera.whiteBalanceMode = AVCaptureWhiteBalanceModeAutoWhiteBalance;
            }
            self.aeAfWbLocked = NO;
        } @catch (__unused NSException *exception) {
            // Ignore a transient device-state exception rather than taking down
            // the recorder for a tap-to-focus request.
        } @finally {
            [camera unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)finishAEAFWBLockForDevice:(AVCaptureDevice *)device
                            point:(CGPoint)point
                         deadline:(CFTimeInterval)deadline
                       completion:(void (^)(BOOL locked))completion {
    if (self.reconfiguring || !device || device != self.camera) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }

    BOOL settled = YES;
    @try {
        settled = !device.isAdjustingFocus && !device.isAdjustingExposure && !device.isAdjustingWhiteBalance;
    } @catch (__unused NSException *exception) {
        settled = YES;
    }
    if (!settled && CACurrentMediaTime() < deadline) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), self.sessionQueue, ^{
            [self finishAEAFWBLockForDevice:device point:point deadline:deadline completion:completion];
        });
        return;
    }

    NSError *error = nil;
    __block BOOL locked = NO;
    if ([device lockForConfiguration:&error]) {
        @try {
            BOOL focusOK = YES, exposureOK = YES, wbOK = YES;
            if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
                device.focusMode = AVCaptureFocusModeLocked;
            } else if (device.isLockingFocusWithCustomLensPositionSupported) {
                [device setFocusModeLockedWithLensPosition:device.lensPosition completionHandler:nil];
            } else {
                focusOK = NO;
            }

            if ([device isExposureModeSupported:AVCaptureExposureModeLocked]) {
                device.exposureMode = AVCaptureExposureModeLocked;
            } else if ([device isExposureModeSupported:AVCaptureExposureModeCustom]) {
                CMTime duration = device.exposureDuration;
                float iso = device.ISO;
                [device setExposureModeCustomWithDuration:duration ISO:iso completionHandler:nil];
            } else {
                exposureOK = NO;
            }

            if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
                device.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
            } else if (device.isLockingWhiteBalanceWithCustomDeviceGainsSupported) {
                AVCaptureWhiteBalanceGains gains = device.deviceWhiteBalanceGains;
                float maxGain = MAX(1.0f, device.maxWhiteBalanceGain);
                gains.redGain = isfinite(gains.redGain) ? MIN(maxGain, MAX(1.0f, gains.redGain)) : 1.0f;
                gains.greenGain = isfinite(gains.greenGain) ? MIN(maxGain, MAX(1.0f, gains.greenGain)) : 1.0f;
                gains.blueGain = isfinite(gains.blueGain) ? MIN(maxGain, MAX(1.0f, gains.blueGain)) : 1.0f;
                [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains completionHandler:nil];
            } else {
                wbOK = NO;
            }
            locked = focusOK && exposureOK && wbOK;
            self.aeAfWbLocked = locked;
        } @catch (__unused NSException *exception) {
            locked = NO;
            self.aeAfWbLocked = NO;
        } @finally {
            [device unlockForConfiguration];
        }
    }
    [self refreshControlSnapshotOnSessionQueue];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(locked); });
}

- (void)lockAEAFWBAtPoint:(CGPoint)point completion:(void (^)(BOOL locked))completion {
    point.x = MIN(1.0, MAX(0.0, point.x));
    point.y = MIN(1.0, MAX(0.0, point.y));
    @synchronized (self) { _focusPointStorage = point; }

    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }
        AVCaptureDevice *device = self.camera;
        if (!device) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }
        BOOL configured = YES;
        @try {
            if (device.isFocusPointOfInterestSupported) device.focusPointOfInterest = point;
            if (device.isExposurePointOfInterestSupported) device.exposurePointOfInterest = point;

            if ([device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
                device.focusMode = AVCaptureFocusModeAutoFocus;
            } else if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            }
            if ([device isExposureModeSupported:AVCaptureExposureModeAutoExpose]) {
                device.exposureMode = AVCaptureExposureModeAutoExpose;
            } else if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            }
            if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeAutoWhiteBalance]) {
                device.whiteBalanceMode = AVCaptureWhiteBalanceModeAutoWhiteBalance;
            } else if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
            }
            self.aeAfWbLocked = NO;
        } @catch (__unused NSException *exception) {
            configured = NO;
        } @finally {
            [device unlockForConfiguration];
        }

        if (!configured || self.reconfiguring || device != self.camera) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }
        [self finishAEAFWBLockForDevice:device point:point deadline:(CACurrentMediaTime() + 1.5) completion:completion];
    });
}

- (void)unlockAEAFWB {
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) { self.aeAfWbLocked = NO; return; }
        AVCaptureDevice *device = self.camera;
        if (!device) { self.aeAfWbLocked = NO; return; }
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
            self.aeAfWbLocked = NO;
        } @catch (__unused NSException *exception) {
            self.aeAfWbLocked = NO;
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setCaptureOrientationName:(NSString *)orientationName {
    NSString *name = orientationName.length ? [orientationName copy] : @"portrait";
    dispatch_async(self.captureQueue, ^{
        self->_captureOrientationName = name;
    });
}
- (void)startRecording {
    @synchronized (self) {
        if (self.recording || self.finalizing || self.reconfiguring) return;
        // Mark the request immediately so a near-simultaneous camera-switch tap
        // cannot race the capture-queue setup below.
        self.recording = YES;
    }
    dispatch_async(self.captureQueue, ^{
        if (!self.recording) return; // cancelled before the capture queue claimed the request
        if (self.recorder || self.finalizing || self.reconfiguring || !self.session.isRunning) {
            self.recording = NO;
            [self sendStatus:@"Recorder is not ready yet."];
            return;
        }
        NSMutableDictionary *recordingInfo = [NSMutableDictionary dictionaryWithDictionary:self.captureInfo ?: @{}];
        recordingInfo[@"focus_point_x"] = @(self.computationalFocusPoint.x);
        recordingInfo[@"focus_point_y"] = @(self.computationalFocusPoint.y);
        recordingInfo[@"focus_point_space"] = @"AVCaptureDevice normalized point of interest";
        recordingInfo[@"capture_interface_orientation"] = self.captureOrientationName ?: @"portrait";
        recordingInfo[@"raw_sensor_orientation"] = @"landscapeRight";
        recordingInfo[@"record_audio_enabled"] = @(self.recordAudioEnabled && self.audioOutput != nil);
        [recordingInfo addEntriesFromDictionary:[self cameraControlSnapshot]];
        NSDictionary *audioSettings = (self.recordAudioEnabled && self.audioOutput) ? self.recommendedAudioSettings : @{};
        self.recorder = [[RecordingSession alloc] initWithClock:self.session.synchronizationClock videoSettings:self.recommendedVideoSettings audioSettings:audioSettings captureInfo:recordingInfo];
        if (!self.recorder) {
            self.recording = NO;
            [self sendStatus:@"Recorder start failed: could not create recording session."];
            return;
        }
        [self sendStatus:[self.captureInfo[@"depth_available"] boolValue] ? @"Recording requested - waiting for first synchronized RGB/depth frame..." : @"Recording requested - waiting for first RGB frame..."];
    });
}

- (void)stopRecording {
    dispatch_async(self.captureQueue, ^{
        RecordingSession *recorder = self.recorder;
        if (!recorder) {
            BOOL cancelledPendingStart = self.recording;
            self.recording = NO;
            if (cancelledPendingStart && self.session.isRunning) {
                [self sendStatus:@"Ready - recording start cancelled."];
            }
            return;
        }
        if (self.finalizing) return;

        // Detach the live callback path immediately so no more samples are appended,
        // but keep a strong reference until AVAssetWriter calls its async completion.
        self.recorder = nil;
        self.finalizingRecorder = recorder;
        self.recording = NO;
        self.finalizing = YES;
        [self sendStatus:@"Finalizing master.mov and metadata..."];

        [recorder finishWithCompletion:^(NSURL *url, NSError *error) {
            self.finalizingRecorder = nil;
            self.finalizing = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate captureEngine:self recordingDidFinishAtURL:url error:error];
            });
        }];
    });
}

- (void)processVideoSample:(CMSampleBufferRef)videoSample
                 depthData:(AVDepthData *)depthData
            depthTimestamp:(CMTime)depthTimestamp
              videoDropped:(BOOL)videoDropped
              depthDropped:(BOOL)depthDropped {
    if (self.reconfiguring || !videoSample) return;

    if (self.previewEnabled && depthData && !videoDropped && !depthDropped) {
        self.previewCounter++;
        if ((self.previewCounter & 1ULL) == 0) {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(videoSample);
            if (pixelBuffer) [self.delegate captureEngine:self didOutputPreviewPixelBuffer:pixelBuffer depthData:depthData];
        }
    }

    RecordingSession *recorder = self.recorder;
    if (!recorder) return;
    if (!recorder.isStarted && !videoDropped && CMSampleBufferIsValid(videoSample)) {
        NSError *error = nil;
        if (![recorder startWithVideoSample:videoSample error:&error]) {
            self.recorder = nil; self.recording = NO;
            [self sendStatus:[NSString stringWithFormat:@"Recorder start failed: %@", error.localizedDescription ?: @"unknown"]];
            return;
        }
        [self sendStatus:[NSString stringWithFormat:@"Recording -> %@", recorder.packageURL.lastPathComponent]];
    }
    if (recorder.isStarted) {
        [recorder appendVideoSample:videoSample
                          depthData:depthDropped ? nil : depthData
                     depthTimestamp:depthData ? depthTimestamp : kCMTimeInvalid
                       videoDropped:videoDropped
                       depthDropped:depthDropped];
        self.telemetryCounter++;
        if ((self.telemetryCounter % 15) == 0) {
            BOOL hasDepth = [self.captureInfo[@"depth_available"] boolValue];
            NSString *telemetry = hasDepth
                ? [NSString stringWithFormat:@"RGB %llu | Depth %llu | Drop RGB %llu / D %llu | UTC per frame",
                    (unsigned long long)recorder.videoFrames,(unsigned long long)recorder.depthFrames,
                    (unsigned long long)recorder.droppedVideoFrames,(unsigned long long)recorder.droppedDepthFrames]
                : [NSString stringWithFormat:@"RGB %llu | physical lens ? depth/DOF off | UTC per frame",
                    (unsigned long long)recorder.videoFrames];
            [self sendTelemetry:telemetry];
        }
    }
}

- (void)dataOutputSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer didOutputSynchronizedDataCollection:(AVCaptureSynchronizedDataCollection *)collection {
    if (self.reconfiguring || synchronizer != self.synchronizer) return;
    AVCaptureVideoDataOutput *videoOutput = self.videoOutput;
    AVCaptureDepthDataOutput *depthOutput = self.depthOutput;
    if (!videoOutput || !depthOutput) return;
    AVCaptureSynchronizedSampleBufferData *videoData = nil;
    AVCaptureSynchronizedDepthData *depthData = nil;
    @try {
        videoData = (AVCaptureSynchronizedSampleBufferData *)[collection synchronizedDataForCaptureOutput:videoOutput];
        depthData = (AVCaptureSynchronizedDepthData *)[collection synchronizedDataForCaptureOutput:depthOutput];
    } @catch (__unused NSException *exception) { return; }
    if (!videoData) return;
    [self processVideoSample:videoData.sampleBuffer
                   depthData:(!depthData || depthData.depthDataWasDropped) ? nil : depthData.depthData
              depthTimestamp:depthData ? depthData.timestamp : kCMTimeInvalid
                videoDropped:videoData.sampleBufferWasDropped
                depthDropped:(!depthData || depthData.depthDataWasDropped)];
}

- (NSDictionary *)buildControlSnapshotOnSessionQueue {
    NSDictionary *fallback = self.cachedControlSnapshot ?: @{};
    AVCaptureDevice *device = self.camera;
    if (!device || self.reconfiguring) return fallback;

    @try {
        AVCaptureDeviceFormat *format = device.activeFormat;
        if (!format) return fallback;
        double targetFPS = [self.captureInfo[@"target_fps"] doubleValue];
        if (!isfinite(targetFPS) || targetFPS <= 0) targetFPS = 30.0;

        double formatMin = CMTimeGetSeconds(format.minExposureDuration);
        double formatMax = CMTimeGetSeconds(format.maxExposureDuration);
        if (!isfinite(formatMin) || formatMin <= 0) formatMin = 1.0 / 1000000.0;
        if (!isfinite(formatMax) || formatMax <= 0) formatMax = 1.0 / targetFPS;
        double minShutter = MAX(formatMin, 1.0 / 1000000.0);
        double maxShutter = MIN(formatMax, 1.0 / targetFPS);
        if (!isfinite(maxShutter) || maxShutter < minShutter) maxShutter = minShutter;

        // iOS can transiently report 0/out-of-range gains while a virtual camera
        // graph is starting. Passing those raw values back into AVFoundation throws
        // an Objective-C exception (this is the exact crash seen on the device).
        AVCaptureWhiteBalanceGains gains = device.deviceWhiteBalanceGains;
        float maxGain = device.maxWhiteBalanceGain;
        if (!isfinite(maxGain) || maxGain < 1.0f) maxGain = 1.0f;
        gains.redGain = isfinite(gains.redGain) ? MIN(maxGain, MAX(1.0f, gains.redGain)) : 1.0f;
        gains.greenGain = isfinite(gains.greenGain) ? MIN(maxGain, MAX(1.0f, gains.greenGain)) : 1.0f;
        gains.blueGain = isfinite(gains.blueGain) ? MIN(maxGain, MAX(1.0f, gains.blueGain)) : 1.0f;

        float wbTemperature = [fallback[@"control_white_balance_temperature"] floatValue];
        float wbTint = [fallback[@"control_white_balance_tint"] floatValue];
        if (!isfinite(wbTemperature) || wbTemperature < 1000.0f) wbTemperature = 5000.0f;
        if (!isfinite(wbTint)) wbTint = 0.0f;
        @try {
            AVCaptureWhiteBalanceTemperatureAndTintValues wb = [device temperatureAndTintValuesForDeviceWhiteBalanceGains:gains];
            if (isfinite(wb.temperature) && wb.temperature >= 1000.0f && wb.temperature <= 20000.0f) wbTemperature = wb.temperature;
            if (isfinite(wb.tint) && wb.tint >= -1000.0f && wb.tint <= 1000.0f) wbTint = wb.tint;
        } @catch (__unused NSException *exception) {
            // Keep the last known-good values. UI telemetry must never be able to
            // terminate the capture process.
        }

        double shutter = CMTimeGetSeconds(device.exposureDuration);
        if (!isfinite(shutter) || shutter <= 0) shutter = minShutter;
        float iso = device.ISO;
        if (!isfinite(iso)) iso = format.minISO;
        CGFloat minZoom = device.minAvailableVideoZoomFactor;
        CGFloat maxZoom = device.maxAvailableVideoZoomFactor;
        CGFloat zoom = device.videoZoomFactor;
        if (!isfinite(minZoom) || minZoom <= 0) minZoom = 1.0;
        if (!isfinite(maxZoom) || maxZoom < minZoom) maxZoom = minZoom;
        if (!isfinite(zoom)) zoom = minZoom;
        zoom = MIN(maxZoom, MAX(minZoom, zoom));

        return @{
            @"capture_rgb_width": self.captureInfo[@"rgb_width"] ?: @0,
            @"capture_rgb_height": self.captureInfo[@"rgb_height"] ?: @0,
            @"camera_position": @(device.position),
            @"camera_device_type": device.deviceType ?: @"",
            @"camera_switch_factors": device.virtualDeviceSwitchOverVideoZoomFactors ?: @[],
            @"capture_depth_available": @([self.captureInfo[@"depth_available"] boolValue]),
            @"dof_available": @([self.captureInfo[@"dof_available"] boolValue]),
            @"selected_rear_lens_index": @(device.position == AVCaptureDevicePositionBack ? self.activeRearLensIndex : -1),
            @"active_primary_constituent_name": device.activePrimaryConstituentDevice.localizedName ?: @"",
            @"active_primary_constituent_type": device.activePrimaryConstituentDevice.deviceType ?: @"",
            @"control_iso": @(iso),
            @"control_iso_min": @(format.minISO),
            @"control_iso_max": @(format.maxISO),
            @"control_shutter_seconds": @(shutter),
            @"control_shutter_min_seconds": @(minShutter),
            @"control_shutter_max_seconds": @(maxShutter),
            @"control_exposure_bias": @(device.exposureTargetBias),
            @"control_exposure_bias_min": @(device.minExposureTargetBias),
            @"control_exposure_bias_max": @(device.maxExposureTargetBias),
            @"control_exposure_manual": @(device.exposureMode == AVCaptureExposureModeCustom),
            @"control_focus_position": @(device.lensPosition),
            @"control_focus_manual": @(device.focusMode == AVCaptureFocusModeLocked),
            @"control_ae_af_wb_locked": @(self.aeAfWbLocked),
            @"control_white_balance_temperature": @(wbTemperature),
            @"control_white_balance_tint": @(wbTint),
            @"control_white_balance_locked": @(device.whiteBalanceMode == AVCaptureWhiteBalanceModeLocked),
            @"control_zoom": @(zoom),
            @"control_zoom_min": @(minZoom),
            @"control_zoom_max": @(maxZoom),
            @"control_torch_available": @(device.hasTorch),
            @"control_torch_level": @(device.torchMode == AVCaptureTorchModeOn ? device.torchLevel : 0.0f)
        };
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

- (void)refreshControlSnapshotOnSessionQueue {
    if (self.reconfiguring) return;
    NSDictionary *snapshot = [self buildControlSnapshotOnSessionQueue];
    if (snapshot.count) self.cachedControlSnapshot = snapshot;
}

- (NSDictionary *)cameraControlSnapshot {
    // Never make UIKit/settings/remote-control callers touch AVCaptureDevice
    // directly. Return a last-known-good immutable snapshot immediately and ask
    // the serial session queue to refresh it when safe.
    NSDictionary *snapshot = self.cachedControlSnapshot ?: @{};
    dispatch_async(self.sessionQueue, ^{
        if (!self.reconfiguring) [self refreshControlSnapshotOnSessionQueue];
    });
    return snapshot;
}

- (void)setExposureBias:(float)bias {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            float value = isfinite(bias) ? MIN(device.maxExposureTargetBias, MAX(device.minExposureTargetBias, bias)) : 0.0f;
            [device setExposureTargetBias:value completionHandler:nil];
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setAutoExposure {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            }
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setManualExposureISO:(float)iso shutterSeconds:(double)seconds {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device || ![device isExposureModeSupported:AVCaptureExposureModeCustom]) return;
        @try {
            AVCaptureDeviceFormat *format = device.activeFormat;
            if (!format) return;
            double targetFPS = [self.captureInfo[@"target_fps"] doubleValue];
            if (!isfinite(targetFPS) || targetFPS <= 0) targetFPS = 30.0;
            float safeISO = isfinite(iso) ? iso : format.minISO;
            float clampedISO = MIN(format.maxISO, MAX(format.minISO, safeISO));
            double minSeconds = CMTimeGetSeconds(format.minExposureDuration);
            double maxSeconds = MIN(CMTimeGetSeconds(format.maxExposureDuration), 1.0 / targetFPS);
            if (!isfinite(minSeconds) || minSeconds <= 0) minSeconds = 1.0 / 1000000.0;
            if (!isfinite(maxSeconds) || maxSeconds < minSeconds) maxSeconds = minSeconds;
            double safeSeconds = isfinite(seconds) ? seconds : minSeconds;
            double clampedSeconds = MIN(maxSeconds, MAX(minSeconds, safeSeconds));
            NSError *error = nil;
            if (![device lockForConfiguration:&error]) return;
            @try {
                [device setExposureModeCustomWithDuration:CMTimeMakeWithSeconds(clampedSeconds, 1000000)
                                                      ISO:clampedISO
                                        completionHandler:nil];
            } @catch (__unused NSException *exception) {
            } @finally {
                [device unlockForConfiguration];
            }
        } @catch (__unused NSException *exception) {
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setFocusLensPosition:(float)position {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device || !device.isLockingFocusWithCustomLensPositionSupported) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            float value = isfinite(position) ? MIN(1.0f, MAX(0.0f, position)) : 0.5f;
            [device setFocusModeLockedWithLensPosition:value completionHandler:nil];
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setAutoFocus {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            }
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

static AVCaptureWhiteBalanceGains DRLegalWhiteBalanceGains(AVCaptureWhiteBalanceGains gains, AVCaptureDevice *device) {
    float maxGain = device.maxWhiteBalanceGain;
    if (!isfinite(maxGain) || maxGain < 1.0f) maxGain = 1.0f;
    gains.redGain = isfinite(gains.redGain) ? MIN(maxGain, MAX(1.0f, gains.redGain)) : 1.0f;
    gains.greenGain = isfinite(gains.greenGain) ? MIN(maxGain, MAX(1.0f, gains.greenGain)) : 1.0f;
    gains.blueGain = isfinite(gains.blueGain) ? MIN(maxGain, MAX(1.0f, gains.blueGain)) : 1.0f;
    return gains;
}

- (void)setWhiteBalanceTemperature:(float)temperature tint:(float)tint {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device || !device.isLockingWhiteBalanceWithCustomDeviceGainsSupported) return;
        @try {
            AVCaptureWhiteBalanceTemperatureAndTintValues values;
            values.temperature = isfinite(temperature) ? MIN(10000.0f, MAX(2500.0f, temperature)) : 5000.0f;
            values.tint = isfinite(tint) ? MIN(150.0f, MAX(-150.0f, tint)) : 0.0f;
            AVCaptureWhiteBalanceGains gains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:values];
            gains = DRLegalWhiteBalanceGains(gains, device);
            NSError *error = nil;
            if (![device lockForConfiguration:&error]) return;
            @try {
                [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains completionHandler:nil];
            } @catch (__unused NSException *exception) {
            } @finally {
                [device unlockForConfiguration];
            }
        } @catch (__unused NSException *exception) {
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)setAutoWhiteBalance {
    self.aeAfWbLocked = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
            }
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)updateRearLensMetadataOnSessionQueue {
    if (self.requestedPosition != AVCaptureDevicePositionBack || !self.camera) return;
    NSInteger mm = self.activeRearLensIndex == 0 ? 13 : (self.activeRearLensIndex == 2 ? 65 : 26);
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:self.captureInfo ?: @{}];
    info[@"rear_lens_index"] = @(self.activeRearLensIndex);
    info[@"rear_lens_equivalent_mm"] = @(mm);
    AVCaptureDevice *primary = self.camera.activePrimaryConstituentDevice;
    info[@"active_primary_constituent_name"] = primary.localizedName ?: @"";
    info[@"active_primary_constituent_type"] = primary.deviceType ?: @"";
    self.captureInfo = [info copy];
    NSInteger w=[info[@"rgb_width"] integerValue], h=[info[@"rgb_height"] integerValue];
    NSInteger dw=[info[@"depth_width"] integerValue], dh=[info[@"depth_height"] integerValue];
    double fps=[info[@"target_fps"] doubleValue];
    BOOL hasDepth=[info[@"depth_available"] boolValue];
    if (w>0 && h>0) self.selectedFormatSummary = hasDepth
        ? [NSString stringWithFormat:@"%ldx%ld | %.0f fps | %ldmm | depth %ldx%ld | UTC",(long)w,(long)h,fps,(long)mm,(long)dw,(long)dh]
        : [NSString stringWithFormat:@"%ldx%ld | %.0f fps | %ldmm | RGB only | UTC",(long)w,(long)h,fps,(long)mm];
}

- (void)selectRearLensIndex:(NSInteger)index {
    if (index < 0 || index > 2) return;
    @synchronized (self) {
        if (self.recording || self.finalizing || self.reconfiguring || self.requestedPosition != AVCaptureDevicePositionBack) return;
        if (self.activeRearLensIndex == index && self.session.isRunning) return;
        self.reconfiguring = YES;
    }
    dispatch_async(self.sessionQueue, ^{
        self.requestedRearLensIndex = index;
        self.aeAfWbLocked = NO;
        NSInteger mm = index == 0 ? 13 : (index == 2 ? 65 : 26);
        [self sendStatus:[NSString stringWithFormat:@"Switching to physical %ldmm camera...", (long)mm]];
        @try {
            if (self.session.isRunning) [self.session stopRunning];
        } @catch (NSException *exception) {
            self.reconfiguring = NO;
            [self sendStatus:[NSString stringWithFormat:@"Lens switch failed safely: %@", exception.reason ?: exception.name]];
            return;
        }
        [self configureSessionWithMicrophone:self.microphonePermissionGranted];
    });
}

- (void)setZoomFactor:(CGFloat)factor {
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            CGFloat minZoom = MAX(0.1, device.minAvailableVideoZoomFactor);
            CGFloat maxZoom = MAX(minZoom, device.maxAvailableVideoZoomFactor);
            CGFloat value = isfinite(factor) ? MIN(maxZoom, MAX(minZoom, factor)) : minZoom;
            device.videoZoomFactor = value;
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)switchCameraPosition {
    @synchronized (self) {
        if (self.recording || self.finalizing || self.reconfiguring) return;
        self.reconfiguring = YES;
    }
    dispatch_async(self.sessionQueue, ^{
        self.requestedPosition = self.requestedPosition == AVCaptureDevicePositionBack ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        @try {
            if (self.session.isRunning) [self.session stopRunning];
        } @catch (NSException *exception) {
            self.reconfiguring = NO;
            [self sendStatus:[NSString stringWithFormat:@"Camera switch failed safely: %@", exception.reason ?: exception.name]];
            return;
        }
        [self configureSessionWithMicrophone:self.microphonePermissionGranted];
    });
}

- (void)setTorchLevel:(float)level {
    dispatch_async(self.sessionQueue, ^{
        if (self.reconfiguring) return;
        AVCaptureDevice *device = self.camera;
        if (!device || !device.hasTorch) return;
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return;
        @try {
            if (!isfinite(level) || level <= 0) {
                device.torchMode = AVCaptureTorchModeOff;
            } else {
                float value = MIN(1.0f, MAX(0.01f, level));
                [device setTorchModeOnWithLevel:value error:&error];
            }
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
        [self refreshControlSnapshotOnSessionQueue];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    (void)connection;
    if (self.reconfiguring || !sampleBuffer) return;
    if (output == self.videoOutput && self.depthOutput == nil) {
        [self processVideoSample:sampleBuffer depthData:nil depthTimestamp:kCMTimeInvalid videoDropped:NO depthDropped:YES];
        return;
    }
    if (output == self.audioOutput && self.recordAudioEnabled) {
        RecordingSession *recorder = self.recorder;
        if (recorder && recorder.isStarted) [recorder appendAudioSample:sampleBuffer];
    }
}

@end

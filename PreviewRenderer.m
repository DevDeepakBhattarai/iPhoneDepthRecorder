#import "PreviewRenderer.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

@interface PreviewRenderer ()
@property (nonatomic, readwrite) MTKView *view;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic) dispatch_queue_t previewQueue;
@property (nonatomic, strong) CIImage *latestImage;
@property (nonatomic) BOOL workInFlight;
@property (nonatomic) CGColorSpaceRef colorSpace;
@end

@implementation PreviewRenderer

static float DRClamp01(float x) {
    return fminf(1.0f, fmaxf(0.0f, x));
}

static float DRSmoothstep(float edge0, float edge1, float x) {
    if (edge1 <= edge0) return x >= edge1 ? 1.0f : 0.0f;
    float t = DRClamp01((x - edge0) / (edge1 - edge0));
    return t * t * (3.0f - 2.0f * t);
}

static int DRCompareFloat(const void *a, const void *b) {
    float fa = *(const float *)a;
    float fb = *(const float *)b;
    return (fa > fb) - (fa < fb);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    if (!self) return nil;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    _commandQueue = [device newCommandQueue];
    if (!_commandQueue) return nil;

    _view = [[MTKView alloc] initWithFrame:frame device:device];
    _view.delegate = self;
    _view.paused = YES;
    _view.enableSetNeedsDisplay = NO;
    _view.framebufferOnly = NO;
    _view.opaque = YES;
    _view.backgroundColor = UIColor.blackColor;
    _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

    _ciContext = [CIContext contextWithMTLCommandQueue:_commandQueue options:@{
        kCIContextCacheIntermediates: @NO,
        kCIContextUseSoftwareRenderer: @NO,
    }];
    _previewQueue = dispatch_queue_create("com.deepak.depthrecorder.preview", DISPATCH_QUEUE_SERIAL);
    _colorSpace = CGColorSpaceCreateDeviceRGB();
    _enabled = YES;
    _interfaceOrientation = UIInterfaceOrientationPortrait;
    _blurRadius = 18.0f;
    return self;
}

- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.view.hidden = YES;
        });
    }
}

- (void)updateDrawableSizeForBounds:(CGRect)bounds screenScale:(CGFloat)screenScale {
    CGFloat widthPoints = CGRectGetWidth(bounds);
    CGFloat heightPoints = CGRectGetHeight(bounds);
    if (widthPoints <= 0 || heightPoints <= 0) return;

    // Cap the long drawable edge near 960 px. The preview is a focusing/composition aid,
    // not the recorded master, so this keeps GPU cost predictable on the A14.
    CGFloat aspect = widthPoints / heightPoints;
    CGSize size;
    if (aspect >= 1.0) {
        size.width = 960.0;
        size.height = floor(960.0 / aspect);
    } else {
        size.height = 960.0;
        size.width = floor(960.0 * aspect);
    }
    size.width = MAX(2.0, floor(size.width / 2.0) * 2.0);
    size.height = MAX(2.0, floor(size.height / 2.0) * 2.0);
    self.view.drawableSize = size;
    (void)screenScale;
}

- (float)focusDepthFromFloatMap:(CVPixelBufferRef)map focusPoint:(CGPoint)focusPoint {
    size_t width = CVPixelBufferGetWidth(map);
    size_t height = CVPixelBufferGetHeight(map);
    size_t bpr = CVPixelBufferGetBytesPerRow(map);
    const uint8_t *base = CVPixelBufferGetBaseAddress(map);
    if (!base || width == 0 || height == 0 || bpr < width * sizeof(float)) return 1.0f;

    NSInteger cx = (NSInteger)llround(DRClamp01((float)focusPoint.x) * (double)(width - 1));
    NSInteger cy = (NSInteger)llround(DRClamp01((float)focusPoint.y) * (double)(height - 1));
    const NSInteger radius = 5;
    float values[121];
    size_t count = 0;
    for (NSInteger y = MAX(0, cy - radius); y <= MIN((NSInteger)height - 1, cy + radius); y++) {
        const float *row = (const float *)(base + (size_t)y * bpr);
        for (NSInteger x = MAX(0, cx - radius); x <= MIN((NSInteger)width - 1, cx + radius); x++) {
            float v = row[x];
            if (isfinite(v) && v > 0.05f && v < 20.0f) values[count++] = v;
        }
    }
    if (count == 0) return 1.0f;
    qsort(values, count, sizeof(float), DRCompareFloat);
    return values[count / 2];
}

- (NSData *)maskDataForDepthData:(AVDepthData *)depthData focusPoint:(CGPoint)focusPoint size:(CGSize *)sizeOut {
    if (!depthData) return nil;
    AVDepthData *floatDepth = nil;
    @try {
        floatDepth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : [depthData depthDataByConvertingToDepthDataType:kCVPixelFormatType_DepthFloat32];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    CVPixelBufferRef map = floatDepth.depthDataMap;
    if (!map) return nil;

    if (CVPixelBufferLockBaseAddress(map, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return nil;
    size_t width = CVPixelBufferGetWidth(map);
    size_t height = CVPixelBufferGetHeight(map);
    size_t bpr = CVPixelBufferGetBytesPerRow(map);
    const uint8_t *base = CVPixelBufferGetBaseAddress(map);
    if (!base || width == 0 || height == 0 || bpr < width * sizeof(float) || width > SIZE_MAX / height) {
        CVPixelBufferUnlockBaseAddress(map, kCVPixelBufferLock_ReadOnly);
        return nil;
    }

    float focusDepth = [self focusDepthFromFloatMap:map focusPoint:focusPoint];
    NSMutableData *mask = [NSMutableData dataWithLength:width * height];
    uint8_t *dest = mask.mutableBytes;
    if (!dest) {
        CVPixelBufferUnlockBaseAddress(map, kCVPixelBufferLock_ReadOnly);
        return nil;
    }
    for (size_t y = 0; y < height; y++) {
        const float *row = (const float *)(base + y * bpr);
        for (size_t x = 0; x < width; x++) {
            float d = row[x];
            float amount = 0.0f;
            if (isfinite(d) && d > focusDepth) {
                float delta = d - focusDepth;
                float ramp = DRSmoothstep(0.14f, 0.52f, delta);
                float invSep = fmaxf(0.0f, (1.0f / fmaxf(focusDepth, 0.08f)) - (1.0f / fmaxf(d, 0.08f)));
                amount = DRClamp01(invSep * 1.65f) * ramp;
            }
            dest[y * width + x] = (uint8_t)lrintf(amount * 255.0f);
        }
    }
    CVPixelBufferUnlockBaseAddress(map, kCVPixelBufferLock_ReadOnly);
    if (sizeOut) *sizeOut = CGSizeMake(width, height);
    return mask;
}

- (int)exifOrientationForInterfaceOrientation:(UIInterfaceOrientation)orientation {
    // Raw back-camera buffers are treated as landscape-right sensor coordinates.
    switch (orientation) {
        case UIInterfaceOrientationPortrait: return 6;            // right / 90 CW
        case UIInterfaceOrientationPortraitUpsideDown: return 8;  // left / 90 CCW
        case UIInterfaceOrientationLandscapeLeft: return 3;       // 180
        case UIInterfaceOrientationLandscapeRight: return 1;      // identity
        default: return 6;
    }
}

- (CIImage *)previewImageForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                              depthData:(AVDepthData *)depthData
                             focusPoint:(CGPoint)focusPoint
                           orientation:(UIInterfaceOrientation)orientation {
    CGSize maskSize = CGSizeZero;
    NSData *maskData = [self maskDataForDepthData:depthData focusPoint:focusPoint size:&maskSize];
    if (!maskData || maskSize.width <= 0 || maskSize.height <= 0) return nil;

    CIImage *source = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGRect sourceExtent = source.extent;
    CGFloat sourceWidth = CGRectGetWidth(sourceExtent), sourceHeight = CGRectGetHeight(sourceExtent);
    if (!isfinite(sourceWidth) || !isfinite(sourceHeight) || sourceWidth <= 0 || sourceHeight <= 0) return nil;
    CGFloat targetWidth = MIN(960.0, sourceWidth);
    CGFloat scale = targetWidth / sourceWidth;
    CIImage *smallSource = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect smallExtent = smallSource.extent;

    CIImage *mask = [CIImage imageWithBitmapData:maskData
                                    bytesPerRow:(size_t)maskSize.width
                                           size:maskSize
                                         format:kCIFormatL8
                                     colorSpace:nil];
    CGFloat maskScaleX = CGRectGetWidth(smallExtent) / maskSize.width;
    CGFloat maskScaleY = CGRectGetHeight(smallExtent) / maskSize.height;
    mask = [mask imageByApplyingTransform:CGAffineTransformMakeScale(maskScaleX, maskScaleY)];

    CIFilter *blur = [CIFilter filterWithName:@"CIMaskedVariableBlur"];
    if (!blur) return nil;
    [blur setValue:smallSource forKey:kCIInputImageKey];
    [blur setValue:mask forKey:@"inputMask"];
    [blur setValue:@(self.blurRadius) forKey:kCIInputRadiusKey];
    CIImage *output = blur.outputImage;
    if (!output) return nil;
    output = [output imageByCroppingToRect:smallExtent];
    output = [output imageByApplyingOrientation:[self exifOrientationForInterfaceOrientation:orientation]];

    CGRect extent = output.extent;
    if (extent.origin.x != 0 || extent.origin.y != 0) {
        output = [output imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    }
    return output;
}

- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer
                depthData:(AVDepthData *)depthData
               focusPoint:(CGPoint)focusPoint {
    if (!self.enabled || !pixelBuffer || !depthData) return;
    @synchronized (self) {
        if (self.workInFlight) return;
        self.workInFlight = YES;
    }

    CVPixelBufferRetain(pixelBuffer);
    AVDepthData *retainedDepth = depthData;
    UIInterfaceOrientation orientation = self.interfaceOrientation;
    dispatch_async(self.previewQueue, ^{
        @autoreleasepool {
            __block CIImage *image = nil;
            @try {
                image = [self previewImageForPixelBuffer:pixelBuffer
                                               depthData:retainedDepth
                                              focusPoint:focusPoint
                                            orientation:orientation];
            } @catch (__unused NSException *exception) {
                image = nil;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    self.latestImage = image;
                    if (image && self.enabled && self.view.window) {
                        self.view.hidden = NO;
                        [self.view draw];
                    }
                } @catch (__unused NSException *exception) {
                    self.latestImage = nil;
                } @finally {
                    CVPixelBufferRelease(pixelBuffer);
                    @synchronized (self) {
                        self.workInFlight = NO;
                    }
                }
            });
        }
    });
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    CIImage *image = self.latestImage;
    if (!image || !self.enabled) return;
    CGSize drawableSize = view.drawableSize;
    CGRect extent = image.extent;
    if (!isfinite(drawableSize.width) || !isfinite(drawableSize.height) ||
        drawableSize.width < 1 || drawableSize.height < 1 ||
        !isfinite(CGRectGetWidth(extent)) || !isfinite(CGRectGetHeight(extent)) ||
        CGRectGetWidth(extent) <= 0 || CGRectGetHeight(extent) <= 0) return;

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    @try {
        CGFloat sx = drawableSize.width / CGRectGetWidth(extent);
        CGFloat sy = drawableSize.height / CGRectGetHeight(extent);
        CGFloat scale = MAX(sx, sy);
        if (!isfinite(scale) || scale <= 0) return;
        CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = scaled.extent;
        CGFloat tx = (drawableSize.width - CGRectGetWidth(scaledExtent)) * 0.5 - scaledExtent.origin.x;
        CGFloat ty = (drawableSize.height - CGRectGetHeight(scaledExtent)) * 0.5 - scaledExtent.origin.y;
        scaled = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
        scaled = [scaled imageByCroppingToRect:CGRectMake(0, 0, drawableSize.width, drawableSize.height)];

        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!commandBuffer) return;
        [self.ciContext render:scaled
                  toMTLTexture:drawable.texture
                 commandBuffer:commandBuffer
                        bounds:CGRectMake(0, 0, drawableSize.width, drawableSize.height)
                    colorSpace:self.colorSpace];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    } @catch (__unused NSException *exception) {
        // Live preview is optional. Drop a bad GPU/CoreImage frame instead of
        // terminating the recording application.
    }
}

@end

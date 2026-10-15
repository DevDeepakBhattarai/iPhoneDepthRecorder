#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>

@interface PreviewRenderer : NSObject <MTKViewDelegate>
@property (nonatomic, readonly) MTKView *view;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic) UIInterfaceOrientation interfaceOrientation;
@property (nonatomic) float blurRadius;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)updateDrawableSizeForBounds:(CGRect)bounds screenScale:(CGFloat)screenScale;
- (void)submitPixelBuffer:(CVPixelBufferRef)pixelBuffer
                depthData:(AVDepthData *)depthData
               focusPoint:(CGPoint)focusPoint;
@end

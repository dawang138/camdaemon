#import "CameraCapture.h"
#import "Config.h"
#import "FrameStore.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

@interface CameraCapture () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) Config *config;
@property (nonatomic, strong) FrameStore *store;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic, assign) BOOL running;
@end

@implementation CameraCapture

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store {
    self = [super init];
    if (self) {
        _config = config;
        _store = store;
    }
    return self;
}

- (BOOL)isRunning { return _running; }

- (BOOL)start:(NSError **)error {
    // 摄像头权限：daemon 无 GUI，首次授权需在带界面的 App 或系统设置里完成。
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"摄像头权限被拒绝，请在设置中允许"}];
        return NO;
    }

    _session = [[AVCaptureSession alloc] init];
    _session.sessionPreset = _config.sessionPreset;

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"未找到后置摄像头设备"}];
        return NO;
    }

    NSError *inputErr = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputErr];
    if (!input) {
        if (error) *error = inputErr;
        return NO;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};

    _delegateQueue = dispatch_queue_create("com.local.camdaemon.capture", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:_delegateQueue];

    if ([_session canAddInput:input]) [_session addInput:input];
    if ([_session canAddOutput:output]) [_session addOutput:output];

    [_session startRunning];
    _running = YES;
    return YES;
}

- (void)stop {
    if (_session) [_session stopRunning];
    _running = NO;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    NSData *jpeg = [self encodeJpeg:pixelBuffer
                            quality:_config.snapshotJpegQuality
                            maxWidth:_config.snapshotMaxWidth];
    if (!jpeg) return;

    Frame *frame = [[Frame alloc] init];
    frame.jpeg = jpeg;
    frame.width = (int)CVPixelBufferGetWidth(pixelBuffer);
    frame.height = (int)CVPixelBufferGetHeight(pixelBuffer);
    frame.capturedAt = [NSDate date];
    [_store setFrame:frame];
}

#pragma mark - 编码辅助（纯 CoreGraphics/CPU，不初始化 GL/EAGL/CoreImage）

- (NSData *)encodeJpeg:(CVPixelBufferRef)pixelBuffer quality:(CGFloat)q maxWidth:(int)maxWidth {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t srcW = CVPixelBufferGetWidth(pixelBuffer);
    size_t srcH = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    if (!baseAddress) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

    CGContextRef srcContext = CGBitmapContextCreate(baseAddress, srcW, srcH, 8, bytesPerRow, colorSpace, bitmapInfo);
    if (!srcContext) {
        CGColorSpaceRelease(colorSpace);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return nil;
    }

    CGImageRef sourceImage = CGBitmapContextCreateImage(srcContext);
    CGContextRelease(srcContext);
    if (!sourceImage) {
        CGColorSpaceRelease(colorSpace);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return nil;
    }

    size_t dstW = srcW;
    size_t dstH = srcH;
    if (maxWidth > 0 && srcW > (size_t)maxWidth) {
        CGFloat scale = (CGFloat)maxWidth / (CGFloat)srcW;
        dstW = (size_t)maxWidth;
        dstH = (size_t)(srcH * scale);
    }

    CGImageRef outputImage = sourceImage;
    CGContextRef dstContext = NULL;
    if (dstW != srcW || dstH != srcH) {
        dstContext = CGBitmapContextCreate(NULL, dstW, dstH, 8, 0, colorSpace, bitmapInfo);
        if (dstContext) {
            CGContextDrawImage(dstContext, CGRectMake(0, 0, dstW, dstH), sourceImage);
            CGImageRef scaled = CGBitmapContextCreateImage(dstContext);
            if (scaled) {
                outputImage = scaled;
            } else {
                CGImageRelease(sourceImage);
                sourceImage = NULL;
                CGColorSpaceRelease(colorSpace);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                return nil;
            }
        }
    }

    UIImage *image = [UIImage imageWithCGImage:outputImage];
    NSData *data = UIImageJPEGRepresentation(image, q);

    if (dstContext) {
        CGContextRelease(dstContext);
        if (outputImage != sourceImage) CGImageRelease(outputImage);
    }
    if (sourceImage) CGImageRelease(sourceImage);
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return data;
}

@end

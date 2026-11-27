#import "CameraCapture.h"
#import "Config.h"
#import "FrameStore.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

@interface CameraCapture () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) Config *config;
@property (nonatomic, strong) FrameStore *store;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) BOOL running;
@end

@implementation CameraCapture

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store {
    self = [super init];
    if (self) {
        _config = config;
        _store = store;
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
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

#pragma mark - 编码辅助

- (NSData *)encodeJpeg:(CVPixelBufferRef)pixelBuffer quality:(CGFloat)q maxWidth:(int)maxWidth {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGFloat w = CVPixelBufferGetWidth(pixelBuffer);
    CGFloat h = CVPixelBufferGetHeight(pixelBuffer);

    if (maxWidth > 0 && w > maxWidth) {
        CGFloat scale = maxWidth / w;
        ciImage = [ciImage transformedBy:CGAffineTransformMakeScale(scale, scale)];
        w *= scale; h *= scale;
    }

    CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
    if (!cgImage) return nil;

    UIImage *image = [UIImage imageWithCGImage:cgImage];
    NSData *data = UIImageJPEGRepresentation(image, q);
    CGImageRelease(cgImage);
    return data;
}

@end

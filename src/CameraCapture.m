#import "CameraCapture.h"
#import "Config.h"
#import "FrameStore.h"
#import "Logger.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

@interface CameraCapture () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) Config *config;
@property (nonatomic, strong) FrameStore *store;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic, strong) dispatch_source_t retryTimer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL gotFrame;
@property (nonatomic, assign) BOOL sessionBuilt;
@property (nonatomic, assign) NSUInteger retryCount;
@end

@implementation CameraCapture

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store {
    self = [super init];
    if (self) {
        _config = config;
        _store = store;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(sessionStarted:)
                       name:AVCaptureSessionDidStartRunningNotification object:nil];
        [nc addObserver:self selector:@selector(sessionRuntimeError:)
                       name:AVCaptureSessionRuntimeErrorNotification object:nil];
        [nc addObserver:self selector:@selector(sessionInterrupted:)
                       name:AVCaptureSessionWasInterruptedNotification object:nil];
        [nc addObserver:self selector:@selector(sessionInterruptionEnded:)
                       name:AVCaptureSessionInterruptionEndedNotification object:nil];
    }
    return self;
}

- (void)sessionStarted:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: DidStartRunning, isRunning=%d", _session.isRunning);
}

- (void)sessionRuntimeError:(NSNotification *)note {
    NSError *err = note.userInfo[AVCaptureSessionErrorKey];
    SBDebug(@"[camdaemon] 会话通知: RuntimeError %@", err ? err.localizedDescription : @"(nil)");
}

- (void)sessionInterrupted:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: WasInterrupted, userInfo=%@", note.userInfo);
}

- (void)sessionInterruptionEnded:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: InterruptionEnded，重新 startRunning");
    [self tryStartRunning];
}

- (BOOL)isRunning { return _running; }

// 会话只建一次；startRunning 可重复调用。被中断/后台吊销后由中断结束回调或定时兜底重试。
- (void)tryStartRunning {
    if (!_session) return;
    if (_session.isRunning) { _running = YES; return; }
    _retryCount++;
    SBDebug(@"[camdaemon] tryStartRunning 第 %lu 次", (unsigned long)_retryCount);
    [_session startRunning];
    SBDebug(@"[camdaemon] startRunning 后 isRunning=%d", _session.isRunning);
    _running = YES;
}

// 定时兜底：未出帧且会话未跑起来时，周期性重试 startRunning。
- (void)startRetryTimer {
    if (_retryTimer) return;
    _retryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _delegateQueue);
    dispatch_source_set_timer(_retryTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak __typeof__(self) wself = self;
    dispatch_source_set_event_handler(_retryTimer, ^{
        __strong __typeof__(wself) sself = wself;
        if (!sself || sself.gotFrame) return;
        if (!sself.session.isRunning) [sself tryStartRunning];
    });
    dispatch_resume(_retryTimer);
}

- (BOOL)start:(NSError **)error {
    // 摄像头权限：daemon 无 GUI，首次授权需在带界面的 App 或系统设置里完成。
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    NSString *st;
    switch (status) {
        case AVAuthorizationStatusNotDetermined: st = @"NotDetermined"; break;
        case AVAuthorizationStatusRestricted:    st = @"Restricted"; break;
        case AVAuthorizationStatusDenied:        st = @"Denied"; break;
        case AVAuthorizationStatusAuthorized:    st = @"Authorized"; break;
        default: st = @"Unknown"; break;
    }
    SBDebug(@"[camdaemon] 摄像头授权状态: %@ (%d)", st, (int)status);
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"摄像头权限%@(%d)", st, (int)status]}];
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
    SBDebug(@"[camdaemon] device: position=%ld uniqueID=%@ name=%@ activeFormat=%@",
          (long)device.position, device.uniqueID, device.localizedName,
          device.activeFormat.formatDescription != nil ? @"yes" : @"no");

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

    BOOL canIn = [_session canAddInput:input];
    BOOL canOut = [_session canAddOutput:output];
    SBDebug(@"[camdaemon] canAddInput=%d canAddOutput=%d", canIn, canOut);
    if (canIn) [_session addInput:input];
    if (canOut) [_session addOutput:output];
    SBDebug(@"[camdaemon] session inputs=%lu outputs=%lu",
          (unsigned long)_session.inputs.count, (unsigned long)_session.outputs.count);

    _sessionBuilt = YES;
    // constructor 在 SB 启动早期执行，此时界面/前台状态未就绪；延迟到前台就绪后再 startRunning。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   _delegateQueue, ^{ [self tryStartRunning]; });
    [self startRetryTimer];
    _running = YES;
    return YES;
}

- (void)stop {
    if (_retryTimer) { dispatch_source_cancel(_retryTimer); _retryTimer = nil; }
    if (_session) [_session stopRunning];
    _running = NO;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    if (!_gotFrame) {
        _gotFrame = YES;
        SBDebug(@"[camdaemon] 首帧到达: %zux%zu",
              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
    }

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

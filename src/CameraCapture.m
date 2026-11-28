#import "CameraCapture.h"
#import "Config.h"
#import "FrameStore.h"
#import "AudioStore.h"
#import "Logger.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <time.h>
#import <string.h>

static NSTimeInterval MonoNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (NSTimeInterval)ts.tv_sec + (NSTimeInterval)ts.tv_nsec / 1.0e9;
}

@interface CameraCapture () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) Config *config;
@property (nonatomic, strong) FrameStore *store;
@property (nonatomic, strong) AudioStore *audioStore;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureDeviceInput *input;
@property (nonatomic, strong) AVCaptureVideoDataOutput *output;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic, strong) dispatch_source_t retryTimer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL gotFrame;
@property (nonatomic, assign) BOOL sessionBuilt;
@property (nonatomic, assign) NSUInteger retryCount;
@property (nonatomic, assign) NSTimeInterval lastRebuildMono;
@end

@implementation CameraCapture

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store audioStore:(AudioStore *)audioStore {
    self = [super init];
    if (self) {
        _config = config;
        _store = store;
        _audioStore = audioStore;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(sessionStarted:)
                       name:AVCaptureSessionDidStartRunningNotification object:nil];
        [nc addObserver:self selector:@selector(sessionRuntimeError:)
                       name:AVCaptureSessionRuntimeErrorNotification object:nil];
        [nc addObserver:self selector:@selector(sessionInterrupted:)
                       name:AVCaptureSessionWasInterruptedNotification object:nil];
        [nc addObserver:self selector:@selector(sessionInterruptionEnded:)
                       name:AVCaptureSessionInterruptionEndedNotification object:nil];
        // 唤醒 / 回前台后复查帧是否陈旧，陈旧则重建。
        [nc addObserver:self selector:@selector(onForegroundWake:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onForegroundWake:)
                       name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)sessionStarted:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: DidStartRunning, isRunning=%d", _session.isRunning);
}

- (void)sessionRuntimeError:(NSNotification *)note {
    NSError *err = note.userInfo[AVCaptureSessionErrorKey];
    SBDebug(@"[camdaemon] 会话通知: RuntimeError %@", err ? err.localizedDescription : @"(nil)");
    _gotFrame = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   _delegateQueue, ^{ [self rebuildSession]; });
}

- (void)sessionInterrupted:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: WasInterrupted, userInfo=%@", note.userInfo);
}

- (void)sessionInterruptionEnded:(NSNotification *)note {
    SBDebug(@"[camdaemon] 会话通知: InterruptionEnded，重新 startRunning");
    [self tryStartRunning];
}

- (void)onForegroundWake:(NSNotification *)note {
    SBDebug(@"[camdaemon] 唤醒/回前台通知，复查帧龄");
    dispatch_async(_delegateQueue, ^{ [self rebuildIfStale]; });
}

- (BOOL)isRunning { return _running; }

- (NSTimeInterval)frameAge {
    Frame *f = _store.latestFrame;
    if (!f) return HUGE_VAL;
    return MonoNow() - f.monotonic;
}

- (BOOL)isStale { return [self frameAge] > _config.staleThreshold; }

- (void)setAudioOn:(BOOL)on {
    [Config setAudioOn:on];
    SBDebug(@"[camdaemon] 音频开关切换 -> %d（重建会话挂/卸麦克风）", (int)on);
    if (!on) [_audioStore clear];
    if (!_delegateQueue) { [self rebuildSession]; return; }
    dispatch_async(_delegateQueue, ^{ [self rebuildSession]; });
}

- (void)tryStartRunning {
    if (!_session) return;
    if (_session.isRunning) { _running = YES; return; }
    _retryCount++;
    SBDebug(@"[camdaemon] tryStartRunning 第 %lu 次", (unsigned long)_retryCount);
    [_session startRunning];
    SBDebug(@"[camdaemon] startRunning 后 isRunning=%d", _session.isRunning);
    _running = _session.isRunning;
}

- (void)rebuildSession {
    SBDebug(@"[camdaemon] 重建采集会话");
    [self buildSession];
    [self tryStartRunning];
}

// 陈旧且距上次重建超过退避窗口（10s）才重建，避免反复抖动。
- (void)rebuildIfStale {
    if (!_session) return;
    if (!_session.isRunning) { [self tryStartRunning]; return; }
    if ([self isStale]) {
        NSTimeInterval now = MonoNow();
        if (now - _lastRebuildMono > 10.0) {
            _lastRebuildMono = now;
            SBDebug(@"[camdaemon] 帧陈旧 %.1fs，重建会话", [self frameAge]);
            [self rebuildSession];
        }
    }
}

// 定时兜底：会话未跑起来则重试；在跑但帧陈旧则（退避）重建。
- (void)startRetryTimer {
    if (_retryTimer) return;
    _retryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _delegateQueue);
    dispatch_source_set_timer(_retryTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak __typeof__(self) wself = self;
    dispatch_source_set_event_handler(_retryTimer, ^{
        __strong __typeof__(wself) sself = wself;
        if (!sself || !sself.session) return;
        [sself rebuildIfStale];
    });
    dispatch_resume(_retryTimer);
}

- (BOOL)start:(NSError **)error {
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

    if (_config.audioOn) {
        AVAuthorizationStatus ast = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        SBDebug(@"[camdaemon] 麦克风授权状态: %d", (int)ast);
    }

    if (![self buildSession]) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"未找到后置摄像头设备"}];
        return NO;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   _delegateQueue, ^{ [self tryStartRunning]; });
    [self startRetryTimer];
    _running = YES;
    return YES;
}

- (BOOL)buildSession {
    if (_session) { [_session stopRunning]; _session = nil; }
    _input = nil;
    _output = nil;
    _audioInput = nil;
    _audioOutput = nil;

    _session = [[AVCaptureSession alloc] init];
    _session.sessionPreset = _config.sessionPreset;

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) return NO;
    SBDebug(@"[camdaemon] device: position=%ld uniqueID=%@ name=%@ activeFormat=%@",
          (long)device.position, device.uniqueID, device.localizedName,
          device.activeFormat.formatDescription != nil ? @"yes" : @"no");

    _input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
    if (!_input) return NO;

    _output = [[AVCaptureVideoDataOutput alloc] init];
    _output.alwaysDiscardsLateVideoFrames = YES;
    _output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};

    if (!_delegateQueue) _delegateQueue = dispatch_queue_create("com.local.camdaemon.capture", DISPATCH_QUEUE_SERIAL);
    [_output setSampleBufferDelegate:self queue:_delegateQueue];

    BOOL canIn = [_session canAddInput:_input];
    BOOL canOut = [_session canAddOutput:_output];
    SBDebug(@"[camdaemon] canAddInput=%d canAddOutput=%d", canIn, canOut);
    if (canIn) [_session addInput:_input];
    if (canOut) [_session addOutput:_output];

    // 麦克风音频采集（PCM 直传）。
    if (_config.audioOn) {
        AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (mic) {
            _audioInput = [AVCaptureDeviceInput deviceInputWithDevice:mic error:NULL];
            _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
            [_audioOutput setSampleBufferDelegate:self queue:_delegateQueue];
            if (_audioInput && [_session canAddInput:_audioInput]) {
                [_session addInput:_audioInput];
                SBDebug(@"[camdaemon] 麦克风输入已挂载");
            } else {
                SBDebug(@"[camdaemon] 麦克风输入挂接失败");
            }
            if (_audioOutput && [_session canAddOutput:_audioOutput]) {
                [_session addOutput:_audioOutput];
            }
        } else {
            SBDebug(@"[camdaemon] 未找到麦克风设备");
        }
    }

    SBDebug(@"[camdaemon] session inputs=%lu outputs=%lu",
          (unsigned long)_session.inputs.count, (unsigned long)_session.outputs.count);

    _sessionBuilt = YES;
    return YES;
}

- (void)stop {
    if (_retryTimer) { dispatch_source_cancel(_retryTimer); _retryTimer = nil; }
    if (_session) [_session stopRunning];
    _session = nil;
    _input = nil;
    _output = nil;
    _audioInput = nil;
    _audioOutput = nil;
    _running = NO;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection {

    if (output == _audioOutput) {
        [self handleAudioSampleBuffer:sampleBuffer];
        return;
    }

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

#pragma mark - 音频 PCM 转换

// 将音频样本缓冲转成目标采样率、单声道、S16 PCM；写进 AudioStore。
- (void)handleAudioSampleBuffer:(CMSampleBufferRef)sb {
    if (!_audioStore) return;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)fmt);
    if (!asbd) return;

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return;
    size_t byteLen = CMBlockBufferGetDataLength(bb);
    if (byteLen == 0) return;

    NSMutableData *raw = [NSMutableData dataWithLength:byteLen];
    CMBlockBufferCopyDataBytes(bb, 0, byteLen, raw.mutableBytes);

    int inRate = (int)asbd->mSampleRate;
    int inCh = asbd->mChannelsPerFrame;
    BOOL isFloat = (asbd->mFormatID == kAudioFormatLinearPCM && asbd->mBitsPerChannel == 32);
    BOOL isInterleaved = !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    int targetRate = _config.audioSampleRate;

    // 先解析为单声道浮点序列。
    size_t perFrame = asbd->mBitsPerChannel / 8;
    size_t inFrames;
    if (isInterleaved) {
        inFrames = byteLen / (perFrame * inCh);
    } else {
        inFrames = byteLen / perFrame; // 非交错：取第一声道近似
    }

    NSMutableArray *mono = [NSMutableArray arrayWithCapacity:inFrames];
    const char *bytes = raw.bytes;
    for (size_t i = 0; i < inFrames; i++) {
        float acc = 0;
        for (int c = 0; c < inCh; c++) {
            size_t off;
            if (isInterleaved) off = (i * inCh + c) * perFrame;
            else off = i * perFrame;
            if (off + perFrame > byteLen) break;
            float v = 0;
            if (isFloat) {
                float f; memcpy(&f, bytes + off, sizeof(f)); v = f;
            } else {
                int16_t s; memcpy(&s, bytes + off, sizeof(s)); v = s / 32768.0f;
            }
            acc += v;
        }
        if (inCh > 1) acc /= (float)inCh;
        [mono addObject:@(acc)];
    }

    // 线性抽点重采样到目标采样率。
    NSMutableData *pcm = [NSMutableData data];
    if (inRate <= 0) inRate = targetRate;
    double step = (double)inRate / (double)targetRate;
    for (int t = 0; ; t++) {
        double src = t * step;
        if (src >= mono.count) break;
        size_t i0 = (size_t)floor(src);
        size_t i1 = MIN(i0 + 1, mono.count - 1);
        float f0 = [mono[i0] floatValue];
        float f1 = [mono[i1] floatValue];
        float frac = (float)(src - i0);
        float v = f0 + (f1 - f0) * frac;
        v = MAX(-1.0f, MIN(1.0f, v));
        int16_t s16 = (int16_t)lroundf(v * 32767.0f);
        [pcm appendBytes:&s16 length:sizeof(s16)];
    }

    if (pcm.length > 0) {
        [_audioStore setPcmData:pcm sampleRate:targetRate channels:1 bits:16];
    }
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

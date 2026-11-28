#import <Foundation/Foundation.h>

@class Config;
@class FrameStore;
@class AudioStore;

/// 内嵌最小 HTTP 服务（零外部依赖，BSD socket）。
/// 端点：/health.json、/capabilities.json、/snapshot.jpg、/stream(MJPEG)、/audio(PCM 分块流)。
@interface HttpServer : NSObject

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store audioStore:(AudioStore *)audioStore;
- (BOOL)start:(NSError **)error;
- (void)stop;

/// 回读采集会话是否运行（由 main 注入，避免循环引用）。
@property (nonatomic, copy) BOOL (^runningCheck)(void);
/// 回读最近一帧的单调时钟龄（秒）；无帧返回巨大值。
@property (nonatomic, copy) NSTimeInterval (^frameAgeCheck)(void);
/// 运行时切换麦克风音频开关（由 main 注入到 CameraCapture）。
@property (nonatomic, copy) void (^audioOnSetter)(BOOL on);

@end

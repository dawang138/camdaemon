#import <Foundation/Foundation.h>

@class Config;
@class FrameStore;
@class AudioStore;

/// 后置摄像头采集会话：AVFoundation 出帧，编码 JPEG 写入 FrameStore；
/// 音频采集写入 AudioStore。流与快照共用同一会话、同一最新帧。
@interface CameraCapture : NSObject

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store audioStore:(AudioStore *)audioStore;

/// 启动采集会话。成功返回 YES；失败通过 error 带出原因。
- (BOOL)start:(NSError **)error;
- (void)stop;
- (BOOL)isRunning;

/// 最近一帧的单调时钟龄（秒）；无帧返回巨大值。
- (NSTimeInterval)frameAge;
/// 是否陈旧（在跑但超过阈值无新帧）。
- (BOOL)isStale;

@end

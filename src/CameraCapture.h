#import <Foundation/Foundation.h>

@class Config;
@class FrameStore;

/// 后置摄像头采集会话：AVFoundation 出帧，编码 JPEG 写入 FrameStore。
/// 流与快照共用同一会话、同一最新帧；不开独立采集会话。
@interface CameraCapture : NSObject

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store;

/// 启动采集会话。成功返回 YES；失败通过 error 带出原因。
- (BOOL)start:(NSError **)error;
- (void)stop;
- (BOOL)isRunning;

@end

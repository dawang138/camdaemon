#import <Foundation/Foundation.h>

/// 一帧已编码好的 JPEG（流与快照共用同一采集会话的最新帧）。
@interface Frame : NSObject
@property (nonatomic, strong) NSData *jpeg;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, strong) NSDate *capturedAt;
@end

/// 线程安全的最新帧缓存：只保留最近一帧，不做录像缓存。
@interface FrameStore : NSObject
- (void)setFrame:(Frame *)frame;
- (Frame *)latestFrame;
@end

#import <Foundation/Foundation.h>

/// 最近一块 PCM 音频（音频流与 /audio 端点共用）。
@interface PcmChunk : NSObject
@property (nonatomic, strong) NSData *data;      ///< S16 PCM，单声道
@property (nonatomic, assign) int sampleRate;
@property (nonatomic, assign) int channels;
@property (nonatomic, assign) int bits;
@property (nonatomic, assign) NSUInteger seq;
@property (nonatomic, assign) NSTimeInterval monotonic;
@end

/// 线程安全的最近音频块缓存：只保留最近一块，不做录像/录音缓存。
@interface AudioStore : NSObject
- (void)setPcmData:(NSData *)data sampleRate:(int)rate channels:(int)ch bits:(int)bits;
- (PcmChunk *)latestPcm;
/// 清空最近音频块（关闭麦克风时调用，避免残留旧块被当作在线音频）。
- (void)clear;
@end

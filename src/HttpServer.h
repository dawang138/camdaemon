#import <Foundation/Foundation.h>

@class Config;
@class FrameStore;

/// 内嵌最小 HTTP 服务（零外部依赖，BSD socket）。
/// 端点：/health.json、/capabilities.json、/snapshot.jpg、/stream(MJPEG)。
@interface HttpServer : NSObject

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store;
- (BOOL)start:(NSError **)error;
- (void)stop;

/// 回读采集会话是否运行（由 main 注入，避免循环引用）。
@property (nonatomic, copy) BOOL (^runningCheck)(void);

@end

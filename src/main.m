#import <Foundation/Foundation.h>

#import "Config.h"
#import "FrameStore.h"
#import "CameraCapture.h"
#import "HttpServer.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Config *config = [Config defaultConfig];
        FrameStore *store = [[FrameStore alloc] init];
        CameraCapture *capture = [[CameraCapture alloc] initWithConfig:config store:store];
        HttpServer *http = [[HttpServer alloc] initWithConfig:config store:store];
        http.runningCheck = ^BOOL { return capture.isRunning; };

        NSError *err = nil;
        if (![capture start:&err]) {
            NSLog(@"[camdaemon] 采集启动失败: %@", err.localizedDescription);
        }
        if (![http start:&err]) {
            NSLog(@"[camdaemon] HTTP 启动失败: %@", err.localizedDescription);
        }

        NSLog(@"[camdaemon] 已启动，监听 %@:%d", config.listenHost, config.listenPort);

        // 保活：阶段二前台常亮，阶段三再做 LaunchDaemon 守护策略。
        [[NSRunLoop mainRunLoop] run];
        return 0;
    }
}

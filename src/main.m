#import <Foundation/Foundation.h>

#import "Config.h"
#import "FrameStore.h"
#import "CameraCapture.h"
#import "HttpServer.h"
#import "Logger.h"

static Config       *g_config;
static FrameStore   *g_store;
static CameraCapture *g_capture;
static HttpServer    *g_http;

// dylib 被 ElleKit 注入 SpringBoard 后由构造函数入口装配，无需 main/RunLoop。
__attribute__((constructor))
static void CamDaemonSBInit(void) {
    @autoreleasepool {
        NSBundle *mainBundle = [NSBundle mainBundle];
        SBDebug(@"[camdaemon] tweak loaded: bundlePath=%@ bundleID=%@",
              mainBundle.bundlePath, mainBundle.bundleIdentifier);

        g_config = [Config defaultConfig];
        g_store = [[FrameStore alloc] init];
        g_capture = [[CameraCapture alloc] initWithConfig:g_config store:g_store];
        g_http = [[HttpServer alloc] initWithConfig:g_config store:g_store];
        g_http.runningCheck = ^BOOL { return g_capture.isRunning; };

        NSError *err = nil;
        if (![g_capture start:&err]) {
            SBDebug(@"[camdaemon] 采集启动失败: %@", err.localizedDescription);
        }
        if (![g_http start:&err]) {
            SBDebug(@"[camdaemon] HTTP 启动失败: %@", err.localizedDescription);
        }

        SBDebug(@"[camdaemon] 已启动，监听 %@:%d", g_config.listenHost, g_config.listenPort);
    }
}

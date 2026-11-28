#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>

#import "Config.h"
#import "FrameStore.h"
#import "CameraCapture.h"
#import "HttpServer.h"
#import "Logger.h"

static Config       *g_config;
static FrameStore   *g_store;
static CameraCapture *g_capture;
static HttpServer    *g_http;
static BOOL          g_inited = NO;

// dylib 被 ElleKit 注入 SpringBoard 后由构造函数入口装配，无需 main/RunLoop。
// 同一进程内 constructor 可能被加载通道重复调用，防重入：第二次直接返回。
__attribute__((constructor))
static void CamDaemonSBInit(void) {
    Dl_info info;
    dladdr((const void *)&CamDaemonSBInit, &info);
    const char *selfImage = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "CamDaemonSB")) { selfImage = n; break; }
    }
    SBDebug(@"[camdaemon] constructor pid=%d selfImage=%s initAddr=%p dli_fname=%s g_initedAddr=%p g_inited=%d",
            getpid(), selfImage ? selfImage : "?", (void *)&CamDaemonSBInit,
            info.dli_fname ? info.dli_fname : "?", (void *)&g_inited, (int)g_inited);

    if (g_inited) return;
    g_inited = YES;
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

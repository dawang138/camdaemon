#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// 路线 B hook v5：
// 目标类 FigCaptureClientSessionMonitorClient，其 ivar `_hasBackgroundCameraAccess`(BOOL)
// 是“该 client 是否获准后台采集”的判定位。hook getter 恒返回 YES，
// 让 mediaserverd 不再因后台身份吊销摄像头会话。

static FILE *mpLog(void) { return fopen("/tmp/mediapatch.log", "a"); }

static BOOL Hooked_hasBackgroundCameraAccess(id self, SEL _cmd) {
    static int logged = 0;
    if (!logged) {
        FILE *f = mpLog();
        if (f) { fprintf(f, "[hook] hasBackgroundCameraAccess forced YES\n"); fclose(f); }
        logged = 1;
    }
    return YES;
}

__attribute__((constructor))
static void MediaPatchInit(void) {
    FILE *f = mpLog();
    if (f) fprintf(f, "\n[mediapatch] v5 hook install pid=%d\n", getpid());

    Class cls = objc_getClass("FigCaptureClientSessionMonitorClient");
    if (!cls) {
        if (f) fprintf(f, "[mediapatch] client class NOT FOUND\n");
        if (f) fclose(f);
        return;
    }

    Method m = class_getInstanceMethod(cls, @selector(hasBackgroundCameraAccess));
    if (m) {
        method_setImplementation(m, (IMP)Hooked_hasBackgroundCameraAccess);
        if (f) fprintf(f, "[mediapatch] hooked hasBackgroundCameraAccess\n");
    } else if (f) {
        fprintf(f, "[mediapatch] selector hasBackgroundCameraAccess NOT FOUND\n");
    }

    if (f) fclose(f);
}

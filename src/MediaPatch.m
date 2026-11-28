#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// 路线 B 探针：先验证 ElleKit 能否注入 mediaserverd，并 dump FigCapture 私有类的方法签名，
// 为后续 hook “后台吊销摄像头”定位目标方法。本阶段不 hook 任何方法，只探查 + 写日志。

static void DumpClass(NSString *name) {
    FILE *f = fopen("/tmp/mediapatch.log", "a");
    if (!f) return;
    Class cls = objc_getClass([name UTF8String]);
    fprintf(f, "\n=== class %@ : %s ===\n", name, cls ? "FOUND" : "NOT FOUND");
    if (cls) {
        unsigned int mcount = 0;
        Method *ms = class_copyMethodList(cls, &mcount);
        for (unsigned int i = 0; i < mcount; i++) {
            SEL sel = method_getName(ms[i]);
            const char *types = method_getTypeEncoding(ms[i]);
            fprintf(f, "  -[%s %s] types=%s\n",
                    class_getName(cls), sel_getName(sel), types ? types : "?");
        }
        free(ms);
    }
    fclose(f);
}

__attribute__((constructor))
static void MediaPatchInit(void) {
    FILE *f = fopen("/tmp/mediapatch.log", "a");
    if (f) {
        fprintf(f, "\n[mediapatch] injected pid=%d\n", getpid());
        fclose(f);
    }
    DumpClass(@"FigCaptureClientSessionMonitor");
    DumpClass(@"FigCaptureClientApplicationStateMonitor");
}

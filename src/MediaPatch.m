#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// 路线 B 探针 v4：纯 dump，下钻与吊销链路相关的 FigCapture 关联类，
// 定位真正发 interruption 的入口。写 /tmp/mediapatch.log。

static FILE *mpLog(void) { return fopen("/tmp/mediapatch.log", "a"); }

static void DumpClassDetail(NSString *name) {
    FILE *f = mpLog();
    if (!f) return;
    Class cls = objc_getClass([name UTF8String]);
    fprintf(f, "\n=== class %s : %s ===\n", [name UTF8String], cls ? "FOUND" : "NOT FOUND");
    if (!cls) { fclose(f); return; }

    Class sup = class_getSuperclass(cls);
    fprintf(f, "  superclass = %s\n", sup ? class_getName(sup) : "(none)");

    unsigned int pc = 0;
    Protocol *__unsafe_unretained *ps = class_copyProtocolList(cls, &pc);
    for (unsigned int i = 0; i < pc; i++)
        fprintf(f, "  protocol = %s\n", protocol_getName(ps[i]));
    free(ps);

    unsigned int ic = 0;
    Ivar *iv = class_copyIvarList(cls, &ic);
    fprintf(f, "  ivars (%u):\n", ic);
    for (unsigned int i = 0; i < ic; i++)
        fprintf(f, "    %s : %s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
    free(iv);

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(ms[i]);
        const char *types = method_getTypeEncoding(ms[i]);
        fprintf(f, "  method -[%s %s] types=%s\n", class_getName(cls),
                sel_getName(sel), types ? types : "?");
    }
    free(ms);
    fclose(f);
}

__attribute__((constructor))
static void MediaPatchInit(void) {
    FILE *f = mpLog();
    if (f) fprintf(f, "\n[mediapatch] v4 dump pid=%d\n", getpid());
    if (f) fclose(f);

    const char *classes[] = {
        "FigCaptureClientSessionMonitor",
        "FigCaptureClientSessionMonitorClient",
        "FigCaptureCMSessionMonitor",
        "FigCaptureSessionObservatory",
        "FigCaptureCMSession",
        "BWFigCaptureSession",
    };
    for (int i = 0; i < 6; i++)
        DumpClassDetail([NSString stringWithUTF8String:classes[i]]);
}

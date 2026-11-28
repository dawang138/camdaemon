#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// 路线 B 探针 v2：
//  1) 验证 ElleKit 注入 mediaserverd；
//  2) dump FigCaptureClientSessionMonitor 的父类 / 协议 / ivar；
//  3) 全局扫描 mediaserverd 内 Capture/Monitor/Interruption/ApplicationState 相关类。
// 本阶段仍不 hook，只把逆向线索写进 /tmp/mediapatch.log。

static FILE *logOpen(void) { return fopen("/tmp/mediapatch.log", "a"); }

static void DumpClassDetail(NSString *name) {
    FILE *f = logOpen();
    if (!f) return;
    Class cls = objc_getClass([name UTF8String]);
    fprintf(f, "\n=== class %s : %s ===\n", [name UTF8String], cls ? "FOUND" : "NOT FOUND");
    if (!cls) { fclose(f); return; }

    Class sup = class_getSuperclass(cls);
    fprintf(f, "  superclass = %s\n", sup ? class_getName(sup) : "(none)");

    unsigned int pc = 0;
    Protocol **ps = class_copyProtocolList(cls, &pc);
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

static void ScanClasses(void) {
    FILE *f = logOpen();
    if (!f) return;
    int n = objc_getClassList(NULL, 0);
    Class *buf = calloc((size_t)n, sizeof(Class));
    objc_getClassList(buf, n);
    fprintf(f, "\n=== global class scan (n=%d) ===\n", n);
    const char *keys[] = {"Capture", "Monitor", "Interruption", "ApplicationState", "ClientSession", "FigCapture"};
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(buf[i]);
        for (int k = 0; k < 6; k++) {
            if (strstr(cn, keys[k])) { fprintf(f, "  %s\n", cn); break; }
        }
    }
    free(buf);
    fclose(f);
}

__attribute__((constructor))
static void MediaPatchInit(void) {
    FILE *f = logOpen();
    if (f) { fprintf(f, "\n[mediapatch] injected pid=%d\n", getpid()); fclose(f); }
    DumpClassDetail(@"FigCaptureClientSessionMonitor");
    ScanClasses();
}

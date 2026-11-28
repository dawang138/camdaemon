#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

// 路线 B 诊断 hook v3：
//  1) 注入 mediaserverd（Filter.Executables=mediaserverd）；
//  2) 吞掉 FigCaptureClientSessionMonitor -updateApplicationState，阻断“后台状态变化→吊销会话”；
//  3) 记录 -applicationState 的真实返回值（暂不改返回），用于判明前台/后台状态码。

static IMP orig_updateApplicationState = NULL;
static IMP orig_applicationState = NULL;

static FILE *logf(void) { return fopen("/tmp/mediapatch.log", "a"); }

static void Hooked_updateApplicationState(id self, SEL _cmd) {
    FILE *f = logf();
    if (f) { fprintf(f, "[hook] updateApplicationState swallowed\n"); fclose(f); }
    // 诊断版：不调用原实现，阻断后台状态更新导致的会话吊销。
}

static int Hooked_applicationState(id self, SEL _cmd) {
    int v = 0;
    if (orig_applicationState)
        v = ((int (*)(id, SEL))orig_applicationState)(self, _cmd);
    static int logged = 0;
    if (!logged) {
        FILE *f = logf();
        if (f) { fprintf(f, "[hook] applicationState getter -> %d\n", v); fclose(f); }
        logged = 1;
    }
    return v; // 诊断版：先保持原值，观察状态码。
}

__attribute__((constructor))
static void MediaPatchInit(void) {
    FILE *f = logf();
    if (f) fprintf(f, "\n[mediapatch] hook install pid=%d\n", getpid());

    Class cls = objc_getClass("FigCaptureClientSessionMonitor");
    if (!cls) {
        if (f) fprintf(f, "[mediapatch] class NOT FOUND\n");
        if (f) fclose(f);
        return;
    }

    Method m1 = class_getInstanceMethod(cls, @selector(updateApplicationState));
    if (m1) {
        orig_updateApplicationState = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)Hooked_updateApplicationState);
        if (f) fprintf(f, "[mediapatch] hooked updateApplicationState\n");
    } else if (f) {
        fprintf(f, "[mediapatch] selector updateApplicationState NOT FOUND\n");
    }

    Method m2 = class_getInstanceMethod(cls, @selector(applicationState));
    if (m2) {
        orig_applicationState = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)Hooked_applicationState);
        if (f) fprintf(f, "[mediapatch] hooked applicationState\n");
    } else if (f) {
        fprintf(f, "[mediapatch] selector applicationState NOT FOUND\n");
    }

    if (f) fclose(f);
}

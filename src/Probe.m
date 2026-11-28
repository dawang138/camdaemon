// 探测 tweak：注入 Preferences，运行时确认
//  1) ElleKit 是否把本 dylib 注入设置进程（constructor 落日志）
//  2) PL hook 目标类在 iOS 16.3 是否存在（objc_getClass + 类名枚举）
//  3) 在设置进程上下文 dlopen PreferenceLoader.dylib 的真实 dlerror
// 仅写 /tmp/probe.log，不挂载采集/UI，避免拖垮宿主进程。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <stdarg.h>

static void plog(const char *fmt, ...) {
    FILE *f = fopen("/tmp/probe.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void probe_dl(const char *label, const char *path) {
    dlerror();
    void *h = dlopen(path, RTLD_NOW);
    const char *err = dlerror();
    plog("dlopen[%s] %s -> handle=%p err=%s", label, path, h, err ? err : "(null)");
}

__attribute__((constructor))
static void ProbeInit(void) {
    plog("===== probe pid=%d =====", getpid());

    @autoreleasepool {
        NSBundle *b = [NSBundle mainBundle];
        plog("bundleID=%s", b.bundleIdentifier.UTF8String ? b.bundleIdentifier.UTF8String : "(null)");
        plog("bundlePath=%s", b.bundlePath.UTF8String ? b.bundlePath.UTF8String : "(null)");
    }

    const char *cands[] = {
        "PrefsListController",
        "PSUIPrefsListController",
        "PSListController",
        "PSUIRootListController",
        "RootListController"
    };
    for (int i = 0; i < (int)(sizeof(cands) / sizeof(cands[0])); i++) {
        Class c = objc_getClass(cands[i]);
        plog("getClass(%s) = %p", cands[i], (void *)c);
    }

    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    plog("registered class count=%u", count);
    if (all) {
        for (unsigned int i = 0; i < count; i++) {
            const char *n = class_getName(all[i]);
            if (strstr(n, "Prefs") || strstr(n, "RootList") || strstr(n, "ListController")) {
                plog("  cls: %s", n);
            }
        }
        free(all);
    }

    probe_dl("libprefs", "/var/jb/usr/lib/libprefs.dylib");
    probe_dl("substrate", "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate");
    probe_dl("PL", "/var/jb/usr/lib/TweakInject/PreferenceLoader.dylib");
    plog("===== probe done =====");
}

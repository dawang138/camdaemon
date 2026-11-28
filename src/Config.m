#import "Config.h"

static NSUserDefaults *suiteDefaults(void) {
    static NSUserDefaults *ud;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ud = [[NSUserDefaults alloc] initWithSuiteName:@"com.local.camdaemon"]; });
    return ud;
}

static int envInt(NSString *key, int fallback) {
    NSString *v = NSProcessInfo.processInfo.environment[key];
    if (v.length == 0) return fallback;
    return v.intValue;
}

static CGFloat envFloat(NSString *key, CGFloat fallback) {
    NSString *v = NSProcessInfo.processInfo.environment[key];
    if (v.length == 0) return fallback;
    return v.doubleValue;
}

static NSString *envStr(NSString *key, NSString *fallback) {
    NSString *v = NSProcessInfo.processInfo.environment[key];
    return v.length ? v : fallback;
}

static BOOL envBool(NSString *key, BOOL fallback) {
    NSString *v = NSProcessInfo.processInfo.environment[key];
    if (v.length == 0) return fallback;
    return [v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"];
}

@implementation Config

+ (instancetype)defaultConfig {
    Config *c = [[Config alloc] init];
    return c;
}

- (NSString *)listenHost { return envStr(@"CAM_HOST", @"0.0.0.0"); }
- (int)listenPort { return envInt(@"CAM_PORT", 8090); }
- (NSString *)sessionPreset { return envStr(@"CAM_PRESET", @"AVCaptureSessionPreset1280x720"); }
- (CGFloat)streamJpegQuality { return envFloat(@"CAM_STREAM_Q", 0.6); }
- (CGFloat)snapshotJpegQuality { return envFloat(@"CAM_SNAP_Q", 0.92); }
- (int)streamMaxWidth { return envInt(@"CAM_STREAM_W", 960); }
- (int)snapshotMaxWidth { return envInt(@"CAM_SNAP_W", 1920); }
- (BOOL)verboseLog { return envBool(@"CAM_VERBOSE", YES); }
- (BOOL)audioOn {
    NSUserDefaults *ud = suiteDefaults();
    if ([ud objectForKey:@"audioOn"] != nil) return [ud boolForKey:@"audioOn"];
    return envBool(@"CAM_AUDIO_ON", YES);
}
- (NSTimeInterval)staleThreshold { return envFloat(@"CAM_STALE_SECS", 8.0); }
- (int)audioSampleRate { return envInt(@"CAM_AUDIO_RATE", 16000); }

+ (void)setAudioOn:(BOOL)on {
    [suiteDefaults() setBool:on forKey:@"audioOn"];
}

@end

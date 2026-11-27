#import <Foundation/Foundation.h>

/// 运行配置：默认值 + 环境变量覆盖（部署时也可经 LaunchDaemon plist 传入）。
@interface Config : NSObject

/// 监听地址，0.0.0.0 表示监听所有网卡。
@property (nonatomic, copy, readonly) NSString *listenHost;
/// HTTP 监听端口（阶段二独立于现成 App 的 8080，默认 8090）。
@property (nonatomic, assign, readonly) int listenPort;
/// AVCaptureSession 预设：vga640x480 / 720p / 1080p / photo。
@property (nonatomic, copy, readonly) NSString *sessionPreset;
/// 实时流 JPEG 质量 0~1。
@property (nonatomic, assign, readonly) CGFloat streamJpegQuality;
/// 快照 JPEG 质量 0~1。
@property (nonatomic, assign, readonly) CGFloat snapshotJpegQuality;
/// 实时流输出最大宽度（等比缩放，0 表示不缩放）。
@property (nonatomic, assign, readonly) int streamMaxWidth;
/// 快照输出最大宽度（等比缩放，0 表示不缩放）。
@property (nonatomic, assign, readonly) int snapshotMaxWidth;
/// 是否输出详细日志。
@property (nonatomic, assign, readonly) BOOL verboseLog;

+ (instancetype)defaultConfig;

@end

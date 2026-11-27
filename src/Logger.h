#import <Foundation/Foundation.h>

// 同时走 NSLog（syslog）与追加写本地文件，便于无 log show 命令的越狱机排查。
OBJC_EXTERN void SBDebug(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

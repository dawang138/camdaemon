#import "Logger.h"
#import <stdarg.h>

static NSString *const kLogPath = @"/tmp/camdaemon-sb.log";

void SBDebug(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"%@", msg);

    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [[NSDate date] description], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {
        // 日志失败不得拖垮宿主进程
    }
}

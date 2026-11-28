#import "FrameStore.h"
#import <time.h>

static NSTimeInterval MonoNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (NSTimeInterval)ts.tv_sec + (NSTimeInterval)ts.tv_nsec / 1.0e9;
}

@implementation Frame
@end

@interface FrameStore () {
    Frame *_frame;
    dispatch_queue_t _queue;
}
@end

@implementation FrameStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.local.camdaemon.framestore", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)setFrame:(Frame *)frame {
    dispatch_sync(_queue, ^{
        frame.monotonic = MonoNow();
        _frame = frame;
    });
}

- (Frame *)latestFrame {
    __block Frame *f = nil;
    dispatch_sync(_queue, ^{
        f = _frame;
    });
    return f;
}

@end

#import "FrameStore.h"

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

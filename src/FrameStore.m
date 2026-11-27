#import "FrameStore.h"

@implementation Frame
@end

@interface FrameStore ()
@property (nonatomic, strong) Frame *frame;
@property (nonatomic, strong) dispatch_queue_t queue;
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
    dispatch_async(_queue, ^{ self.frame = frame; });
}

- (Frame *)latestFrame {
    __block Frame *f = nil;
    dispatch_sync(_queue, ^{ f = self.frame; });
    return f;
}

@end

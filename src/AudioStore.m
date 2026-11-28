#import "AudioStore.h"
#import <time.h>

static NSTimeInterval MonoNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (NSTimeInterval)ts.tv_sec + (NSTimeInterval)ts.tv_nsec / 1.0e9;
}

@implementation PcmChunk
@end

@interface AudioStore () {
    PcmChunk *_chunk;
    dispatch_queue_t _queue;
    NSUInteger _seq;
}
@end

@implementation AudioStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.local.camdaemon.audiostore", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)setPcmData:(NSData *)data sampleRate:(int)rate channels:(int)ch bits:(int)bits {
    dispatch_sync(_queue, ^{
        _seq++;
        PcmChunk *c = [[PcmChunk alloc] init];
        c.data = data;
        c.sampleRate = rate;
        c.channels = ch;
        c.bits = bits;
        c.seq = _seq;
        c.monotonic = MonoNow();
        _chunk = c;
    });
}

- (PcmChunk *)latestPcm {
    __block PcmChunk *c = nil;
    dispatch_sync(_queue, ^{ c = _chunk; });
    return c;
}

@end

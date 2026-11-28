#import "HttpServer.h"
#import "Config.h"
#import "FrameStore.h"
#import "AudioStore.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static NSString *const kBoundary = @"camdaemonframe";

@interface HttpServer ()
@property (nonatomic, strong) Config *config;
@property (nonatomic, strong) FrameStore *store;
@property (nonatomic, strong) AudioStore *audioStore;
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) BOOL running;
@end

@implementation HttpServer

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store audioStore:(AudioStore *)audioStore {
    self = [super init];
    if (self) { _config = config; _store = store; _audioStore = audioStore; _listenFd = -1; }
    return self;
}

- (BOOL)start:(NSError **)error {
    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:10 userInfo:@{NSLocalizedDescriptionKey: @"socket 创建失败"}];
        return NO;
    }

    int yes = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)_config.listenPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:11 userInfo:@{NSLocalizedDescriptionKey: @"bind 失败（端口被占用？）"}];
        close(_listenFd); _listenFd = -1;
        return NO;
    }
    if (listen(_listenFd, 64) < 0) {
        if (error) *error = [NSError errorWithDomain:@"CamDaemon" code:12 userInfo:@{NSLocalizedDescriptionKey: @"listen 失败"}];
        close(_listenFd); _listenFd = -1;
        return NO;
    }

    _running = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self acceptLoop]; });
    return YES;
}

- (void)stop {
    _running = NO;
    if (_listenFd >= 0) { close(_listenFd); _listenFd = -1; }
}

#pragma mark - 连接处理

- (void)acceptLoop {
    while (_running) {
        int cfd = accept(_listenFd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self handleClient:cfd];
        });
    }
}

- (void)handleClient:(int)cfd {
    char buf[4096];
    ssize_t n = recv(cfd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(cfd); return; }
    buf[n] = 0;

    char method[16] = {0};
    char path[1024] = {0};
    if (sscanf(buf, "%15s %1023s", method, path) != 2) {
        [self sendStatus:400 reason:@"Bad Request" contentType:@"text/plain" body:[@"bad request" dataUsingEncoding:NSUTF8StringEncoding] fd:cfd];
        close(cfd); return;
    }

    NSString *p = [NSString stringWithUTF8String:path];
    NSString *m = [NSString stringWithUTF8String:method];

    if ([m isEqualToString:@"POST"] && [p isEqualToString:@"/config"]) {
        [self writeConfig:cfd bodyBuffer:buf length:n];
    }
    else if ([p isEqualToString:@"/health.json"])       [self writeHealth:cfd];
    else if ([p isEqualToString:@"/capabilities.json"]) [self writeCapabilities:cfd];
    else if ([p isEqualToString:@"/snapshot.jpg"]) [self writeSnapshot:cfd];
    else if ([p isEqualToString:@"/stream"])        [self writeMjpeg:cfd];
    else if ([p isEqualToString:@"/audio"])         [self writeAudio:cfd];
    else                                            [self sendStatus:404 reason:@"Not Found" contentType:@"text/plain" body:[@"not found" dataUsingEncoding:NSUTF8StringEncoding] fd:cfd];

    close(cfd);
}

#pragma mark - 响应

- (void)sendStatus:(int)code reason:(NSString *)reason contentType:(NSString *)ct body:(NSData *)body fd:(int)fd {
    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"HTTP/1.1 %d %@\r\n", code, reason];
    [head appendFormat:@"Content-Type: %@\r\n", ct];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [head appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [head appendString:@"Connection: close\r\n\r\n"];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, headData.bytes, headData.length, 0);
    if (body.length) send(fd, body.bytes, body.length, 0);
}

- (NSString *)isoDate:(NSDate *)date {
    if (!date) return nil;
    NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
    return [f stringFromDate:date];
}

- (void)writeHealth:(int)fd {
    Frame *f = [_store latestFrame];
    BOOL running = _runningCheck ? _runningCheck() : NO;
    NSTimeInterval age = _frameAgeCheck ? _frameAgeCheck() : HUGE_VAL;
    BOOL stale = (age > _config.staleThreshold);

    PcmChunk *chunk = [_audioStore latestPcm];
    NSDictionary *json = @{
        @"status": running ? @"running" : @"stopped",
        @"server": @{ @"port": @(_config.listenPort), @"state": _running ? @"listening" : @"stopped" },
        @"capture": @{
            @"running": @(running),
            @"cameraAvailable": @YES,
            @"width": @(f.width),
            @"height": @(f.height),
            @"lastFrameAt": [self isoDate:f.capturedAt] ?: [NSNull null],
            @"frameAgeSeconds": @(isfinite(age) ? round(age * 10) / 10 : -1),
            @"stale": @(stale)
        },
        @"audio": @{
            @"on": @(_config.audioOn),
            @"hasChunk": @(chunk != nil),
            @"sampleRate": @(chunk.sampleRate),
            @"channels": @(chunk.channels),
            @"bits": @(chunk.bits)
        },
        @"streams": @{
            @"mjpeg": @{ @"activeClients": @0, @"state": _running ? @"idle" : @"stopped" },
            @"snapshot": @{ @"activeClients": @0, @"state": _running ? @"idle" : @"stopped" }
        },
        @"updatedAt": [self isoDate:[NSDate date]] ?: @""
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [self sendStatus:200 reason:@"OK" contentType:@"application/json" body:body fd:fd];
}

- (void)writeCapabilities:(int)fd {
    NSDictionary *json = @{
        @"mjpeg": @YES, @"rtsp": @NO, @"snapshot": @YES,
        @"audio": @(_config.audioOn), @"audioCodec": @"pcm-s16-mono",
        @"torch": @NO, @"zoom": @NO, @"focus": @NO,
        @"streamQualities": @[@"low", @"medium", @"high"],
        @"snapshotQualities": @[@"standard", @"high"]
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [self sendStatus:200 reason:@"OK" contentType:@"application/json" body:body fd:fd];
}

// POST /config：body JSON {"audioOn": true|false}，运行时切换麦克风采集。
- (void)writeConfig:(int)fd bodyBuffer:(const char *)buf length:(ssize_t)n {
    NSDictionary *json = nil;
    NSString *req = [[NSString alloc] initWithBytes:buf length:(size_t)n encoding:NSUTF8StringEncoding];
    if (req) {
        NSRange r = [req rangeOfString:@"\r\n\r\n"];
        if (r.location != NSNotFound) {
            NSData *body = [[req substringFromIndex:r.location + r.length] dataUsingEncoding:NSUTF8StringEncoding];
            json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        }
    }
    if (!json || json[@"audioOn"] == nil) {
        NSData *err = [@"{\"error\":\"missing audioOn\"}" dataUsingEncoding:NSUTF8StringEncoding];
        [self sendStatus:400 reason:@"Bad Request" contentType:@"application/json" body:err fd:fd];
        return;
    }
    BOOL on = [json[@"audioOn"] boolValue];
    if (self.audioOnSetter) self.audioOnSetter(on);
    NSDictionary *resp = @{ @"audioOn": @(on) };
    NSData *respBody = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
    [self sendStatus:200 reason:@"OK" contentType:@"application/json" body:respBody fd:fd];
}

- (void)writeSnapshot:(int)fd {
    Frame *f = [_store latestFrame];
    if (!f || !f.jpeg) {
        [self sendStatus:503 reason:@"Service Unavailable" contentType:@"text/plain"
                     body:[@"no frame yet" dataUsingEncoding:NSUTF8StringEncoding] fd:fd];
        return;
    }
    [self sendStatus:200 reason:@"OK" contentType:@"image/jpeg" body:f.jpeg fd:fd];
}

- (void)writeMjpeg:(int)fd {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: multipart/x-mixed-replace; boundary=%@\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Cache-Control: no-cache\r\n"
        @"Connection: close\r\n\r\n", kBoundary];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, headData.bytes, headData.length, 0);

    while (_running) {
        Frame *f = [_store latestFrame];
        if (f && f.jpeg) {
            NSString *part = [NSString stringWithFormat:@"--%@\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                             kBoundary, (unsigned long)f.jpeg.length];
            NSData *partData = [part dataUsingEncoding:NSUTF8StringEncoding];
            ssize_t s1 = send(fd, partData.bytes, partData.length, 0);
            ssize_t s2 = send(fd, f.jpeg.bytes, f.jpeg.length, 0);
            ssize_t s3 = send(fd, "\r\n", 2, 0);
            if (s1 <= 0 || s2 <= 0 || s3 <= 0) break;
        }
        usleep(66000);  // 约 15 fps
    }
}

// /audio：自定义二进制分块流。帧格式（小端）：
// magic[4]='CP1\0' | seq u32 | sampleRate i32 | bits u16 | channels u16 | length u32 | PCM bytes
- (void)writeAudio:(int)fd {
    NSString *head = @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/octet-stream\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Cache-Control: no-cache\r\n"
        @"X-Audio-Codec: pcm-s16-mono\r\n"
        @"Connection: close\r\n\r\n";
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, headData.bytes, headData.length, 0);

    NSUInteger lastSeq = 0;
    while (_running) {
        PcmChunk *chunk = [_audioStore latestPcm];
        if (chunk && chunk.seq != lastSeq && chunk.data.length > 0) {
            lastSeq = chunk.seq;
            NSMutableData *frame = [NSMutableData data];
            char magic[4] = {'C','P','1',0};
            [frame appendBytes:magic length:4];
            uint32_t seq = (uint32_t)chunk.seq;
            int32_t rate = (int32_t)chunk.sampleRate;
            uint16_t bits = (uint16_t)chunk.bits;
            uint16_t ch = (uint16_t)chunk.channels;
            uint32_t len = (uint32_t)chunk.data.length;
            [frame appendBytes:&seq length:4];
            [frame appendBytes:&rate length:4];
            [frame appendBytes:&bits length:2];
            [frame appendBytes:&ch length:2];
            [frame appendBytes:&len length:4];
            [frame appendData:chunk.data];

            ssize_t s = send(fd, frame.bytes, frame.length, 0);
            if (s <= 0) break;
        }
        usleep(20000);
    }
}

@end

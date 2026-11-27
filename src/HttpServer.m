#import "HttpServer.h"
#import "Config.h"
#import "FrameStore.h"

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
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) BOOL running;
@end

@implementation HttpServer

- (instancetype)initWithConfig:(Config *)config store:(FrameStore *)store {
    self = [super init];
    if (self) { _config = config; _store = store; _listenFd = -1; }
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

    if ([p isEqualToString:@"/health.json"])       [self writeHealth:cfd];
    else if ([p isEqualToString:@"/capabilities.json"]) [self writeCapabilities:cfd];
    else if ([p isEqualToString:@"/snapshot.jpg"]) [self writeSnapshot:cfd];
    else if ([p isEqualToString:@"/stream"])        [self writeMjpeg:cfd];
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
    NSDictionary *json = @{
        @"status": running ? @"running" : @"stopped",
        @"server": @{ @"port": @(_config.listenPort), @"state": _running ? @"listening" : @"stopped" },
        @"capture": @{
            @"running": @(running),
            @"cameraAvailable": @YES,
            @"width": @(f.width),
            @"height": @(f.height),
            @"lastFrameAt": [self isoDate:f.capturedAt] ?: [NSNull null]
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
        @"audio": @NO, @"torch": @NO, @"zoom": @NO, @"focus": @NO,
        @"streamQualities": @[@"low", @"medium", @"high"],
        @"snapshotQualities": @[@"standard", @"high"]
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [self sendStatus:200 reason:@"OK" contentType:@"application/json" body:body fd:fd];
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
            if (s1 <= 0 || s2 <= 0 || s3 <= 0) break;  // 客户端已断开
        }
        usleep(66000);  // 约 15 fps
    }
}

@end

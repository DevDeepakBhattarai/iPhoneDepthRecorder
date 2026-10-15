#import "RemoteControlServer.h"
#import "CaptureEngine.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

@interface RemoteControlServer ()
@property (nonatomic, weak) CaptureEngine *engine;
@property (nonatomic) int listenFD;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t source;
@property (nonatomic, readwrite) uint16_t port;
@end

@implementation RemoteControlServer

- (instancetype)initWithEngine:(CaptureEngine *)engine port:(uint16_t)port {
    self = [super init];
    if (!self) return nil;
    _engine = engine;
    _port = port;
    _listenFD = -1;
    _queue = dispatch_queue_create("com.deepak.depthrecorder.remote", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start:(NSError **)error {
    if (self.source) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        int code = errno;
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    self.listenFD = fd;
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.source, ^{
        [weakSelf acceptAvailableClients];
    });
    dispatch_source_set_cancel_handler(self.source, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.listenFD >= 0) {
            close(strongSelf.listenFD);
            strongSelf.listenFD = -1;
        }
    });
    dispatch_resume(self.source);
    return YES;
}

- (void)stop {
    dispatch_source_t source = self.source;
    self.source = nil;
    if (source) dispatch_source_cancel(source);
    else if (self.listenFD >= 0) { close(self.listenFD); self.listenFD = -1; }
}

- (void)acceptAvailableClients {
    while (self.listenFD >= 0) {
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        int client = accept(self.listenFD, (struct sockaddr *)&peer, &peerLen);
        if (client < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
            return;
        }
        [self handleClient:client];
        close(client);
        // One request per connection keeps the USB control protocol simple and bounded.
        return;
    }
}

static int64_t DRRemoteUTCNs(void) {
    return (int64_t)llround([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

- (NSDictionary *)responseForRequest:(NSDictionary *)request {
    CaptureEngine *engine = self.engine;
    NSString *client = [request[@"client"] isKindOfClass:NSString.class] ? request[@"client"] : @"";
    NSString *command = [request[@"cmd"] isKindOfClass:NSString.class] ? request[@"cmd"] : @"";
    int64_t received = DRRemoteUTCNs();
    if (![client isEqualToString:@"depthrecorder-obs-v1"]) {
        return @{ @"ok": @NO, @"error": @"bad_client", @"utc_ns": @(received) };
    }
    if (!engine) return @{ @"ok": @NO, @"error": @"engine_unavailable", @"utc_ns": @(received) };

    if ([command isEqualToString:@"start_record"]) {
        if (engine.isFinalizing) return @{ @"ok": @NO, @"error": @"finalizing", @"utc_ns": @(received) };
        if (!engine.session.isRunning) return @{ @"ok": @NO, @"error": @"not_ready", @"utc_ns": @(received) };
        BOOL already = engine.isRecording;
        if (!already) [engine startRecording];
        return @{ @"ok": @YES, @"accepted": @"start_record", @"already_recording": @(already), @"utc_ns": @(received) };
    }
    if ([command isEqualToString:@"stop_record"]) {
        if (engine.isRecording) [engine stopRecording];
        return @{ @"ok": @YES, @"accepted": @"stop_record", @"was_recording": @(engine.isRecording), @"utc_ns": @(received) };
    }
    if ([command isEqualToString:@"status"]) {
        return @{ @"ok": @YES, @"recording": @(engine.isRecording), @"finalizing": @(engine.isFinalizing), @"ready": @(engine.session.isRunning), @"utc_ns": @(received), @"format": engine.selectedFormatSummary ?: @"" };
    }
    return @{ @"ok": @NO, @"error": @"unknown_command", @"utc_ns": @(received) };
}

- (void)handleClient:(int)client {
    struct timeval timeout = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint8_t buffer[8192];
    ssize_t n = recv(client, buffer, sizeof(buffer) - 1, 0);
    NSDictionary *response = nil;
    if (n <= 0) {
        response = @{ @"ok": @NO, @"error": @"empty_request", @"utc_ns": @(DRRemoteUTCNs()) };
    } else {
        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)n];
        NSError *jsonError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![object isKindOfClass:NSDictionary.class]) {
            response = @{ @"ok": @NO, @"error": @"invalid_json", @"utc_ns": @(DRRemoteUTCNs()) };
        } else {
            response = [self responseForRequest:(NSDictionary *)object];
        }
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:response ?: @{} options:0 error:nil];
    NSMutableData *line = [out mutableCopy];
    uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    const uint8_t *bytes = line.bytes;
    NSUInteger left = line.length;
    while (left > 0) {
        ssize_t sent = send(client, bytes, left, 0);
        if (sent <= 0) break;
        bytes += sent;
        left -= (NSUInteger)sent;
    }
}

@end

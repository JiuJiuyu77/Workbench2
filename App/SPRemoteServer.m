//
//  SPRemoteServer.m
//

#import "SPRemoteServer.h"
#import "SPCompat.h"
#import "SPStore.h"
#import "SPModels.h"
#import "SPBuilder.h"
#import "SPToolchain.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <unistd.h>
#import <fcntl.h>



@interface SPRemoteServer ()
@property (nonatomic, assign) SPRemoteState state;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, assign) int listenFd;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, copy, nullable) NSString *accessCode;
@property (nonatomic, assign) BOOL running;
@end

@implementation SPRemoteServer

+ (instancetype)shared {
    static SPRemoteServer *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SPRemoteServer new];
        s.state = SPRemoteStateStopped;
        s.listenFd = -1;
        s.acceptQueue = dispatch_queue_create("spark.remote.accept", DISPATCH_QUEUE_SERIAL);
        s.workQueue = dispatch_queue_create("spark.remote.work", DISPATCH_QUEUE_CONCURRENT);
        s.accessCode = [s generateCode];
    });
    return s;
}

- (BOOL)isRunning { return self.running; }

- (NSString *)statusText {
    if (self.running) {
        return [NSString stringWithFormat:@"运行中 · %@ · 访问码 %@", self.baseURL ?: @":", self.accessCode ?: @"-"];
    }
    if (self.state == SPRemoteStateFailed) return @"启动失败（端口可能被占用）";
    return @"已停止";
}

#pragma mark - 启动

- (NSString *)generateCode {
    // 6 位数字，好念好输入
    uint32_t v = 0;
    arc4random_buf(&v, sizeof(v));
    return [NSString stringWithFormat:@"%06u", v % 1000000];
}

- (NSString *)rotateAccessCode {
    self.accessCode = [self generateCode];
    return self.accessCode;
}

- (NSArray<NSString *> *)localIPv4Addresses {
    NSMutableArray *out = [NSMutableArray array];
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) return out;
    for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP)) continue;
        if (a->ifa_flags & IFF_LOOPBACK) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            NSString *s = [NSString stringWithUTF8String:buf];
            if (s.length && ![s hasPrefix:@"169.254."]) [out addObject:s];
        }
    }
    freeifaddrs(addrs);
    return out;
}

- (NSString *)baseURL {
    NSString *ip = [self localIPv4Addresses].firstObject;
    if (!ip.length) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld", ip, (long)self.port];
}

- (BOOL)startWithPort:(NSInteger)port error:(NSError **)error {
    if (self.running) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = SPError(SPErrorCodeIO, @"创建 socket 失败");
        self.state = SPRemoteStateFailed;
        return NO;
    }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        self.state = SPRemoteStateFailed;
        if (error) *error = SPError(SPErrorCodeIO,
            [NSString stringWithFormat:@"端口 %ld 绑定失败：%s", (long)port, strerror(errno)]);
        return NO;
    }
    if (listen(fd, 8) != 0) {
        close(fd);
        self.state = SPRemoteStateFailed;
        if (error) *error = SPError(SPErrorCodeIO, @"listen 失败");
        return NO;
    }

    // 非阻塞 accept，便于 stop 时退出
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    self.listenFd = fd;
    self.port = port;
    self.running = YES;
    self.state = SPRemoteStateRunning;
    self.accessCode = [self generateCode];

    [self acceptLoop];
    SPLog(@"局域网工作台已启动：%@  访问码 %@", self.baseURL ?: @"", self.accessCode);
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.listenFd >= 0) {
        close(self.listenFd);
        self.listenFd = -1;
    }
    self.state = SPRemoteStateStopped;
    SPLog(@"局域网工作台已停止");
}

- (void)acceptLoop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.acceptQueue, ^{
        while (weakSelf.running && weakSelf.listenFd >= 0) {
            struct sockaddr_in peer;
            socklen_t len = sizeof(peer);
            int cl = accept(weakSelf.listenFd, (struct sockaddr *)&peer, &len);
            if (cl < 0) {
                usleep(120 * 1000);
                continue;
            }
            char ipbuf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &peer.sin_addr, ipbuf, sizeof(ipbuf));
            NSString *client = [NSString stringWithUTF8String:ipbuf] ?: @"?";

            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { close(cl); break; }
            dispatch_async(strongSelf.workQueue, ^{
                [strongSelf handleClient:cl from:client];
            });
        }
    });
}

#pragma mark - HTTP 处理

- (void)handleClient:(int)fd from:(NSString *)client {
    @autoreleasepool {
        // 简易超时，防止半开连接卡住线程
        struct timeval tv = { 10, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        NSMutableData *buf = [NSMutableData data];
        char chunk[4096];
        NSUInteger headerEnd = NSNotFound;
        while (buf.length < 256 * 1024) {
            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;
            [buf appendBytes:chunk length:(NSUInteger)n];
            NSRange r = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, buf.length)];
            if (r.location != NSNotFound) { headerEnd = r.location + r.length; break; }
        }
        if (headerEnd == NSNotFound) { [self respond:fd status:400 body:@"bad request"]; close(fd); return; }

        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerEnd)]
                                               encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSString *requestLine = lines.firstObject ?: @"";
        NSArray *parts = [requestLine componentsSeparatedByString:@" "];
        if (parts.count < 2) { [self respond:fd status:400 body:@"bad request"]; close(fd); return; }

        NSString *method = parts[0];
        NSString *target = parts[1];
        NSRange q = [target rangeOfString:@"?"];
        NSString *path = q.location == NSNotFound ? target : [target substringToIndex:q.location];
        NSString *query = q.location == NSNotFound ? @"" : [target substringFromIndex:q.location + 1];

        // 请求体（POST 写文件用）
        NSUInteger contentLength = 0;
        for (NSString *h in lines) {
            if ([h.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = (NSUInteger)[[h substringFromIndex:15] integerValue];
            }
        }
        NSMutableData *body = [[buf subdataWithRange:NSMakeRange(headerEnd, buf.length - headerEnd)] mutableCopy];
        while (body.length < contentLength && contentLength > 0) {
            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;
            [body appendBytes:chunk length:(NSUInteger)n];
        }

        // 鉴权（首页与静态资源放行，API 必须带码）
        if ([path hasPrefix:@"/api/"]) {
            NSString *code = [self valueOfParam:@"code" in:query];
            if (!code.length || ![code isEqualToString:self.accessCode]) {
                [self respond:fd status:401 body:@"{\"ok\":false,\"error\":\"access code required\"}"];
                close(fd);
                return;
            }
        }

        NSData *response = [self routeMethod:method path:path query:query body:body];
        [self writeAll:fd data:response];
        close(fd);
    }
}

- (NSData *)routeMethod:(NSString *)method path:(NSString *)path query:(NSString *)query body:(NSData *)body {
    // 首页：从包内 Remote/index.html 读取（CI 已打进去）
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"]) {
        NSData *html = [self remoteIndexHTML];
        if (!html) {
            html = [@"<h3>缺少 Remote/index.html（打包时未拷入）</h3>"
                     "<p>API 仍可用：/api/ping?code=xxxxxx</p>" dataUsingEncoding:NSUTF8StringEncoding];
        }
        return [self httpResponse:200 type:@"text/html; charset=utf-8" body:html];
    }

    if ([path isEqualToString:@"/api/ping"]) {
        return [self json:@{@"ok": @YES, @"name": @"Workbench", @"port": @(self.port)}];
    }

    // 列目录
    if ([path isEqualToString:@"/api/list"]) {
        NSString *rel = [self valueOfParam:@"path" in:query] ?: @"";
        NSString *dir = [self resolve:rel];
        if (!dir) return [self json:@{@"ok": @NO, @"error": @"路径越界"}];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *name in [[fm contentsOfDirectoryAtPath:dir error:NULL]
                                sortedArrayUsingSelector:@selector(localizedStandardCompare:)] ?: @[]) {
            if ([name hasPrefix:@"."] && ![name isEqualToString:@".theos"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
            [items addObject:@{
                @"name": name,
                @"dir": @(isDir),
                @"size": @(a.fileSize),
                @"path": [rel stringByAppendingFormat:@"%@%@", rel.length ? @"/" : @"", name],
            }];
        }
        return [self json:@{@"ok": @YES, @"path": rel, @"items": items}];
    }

    // 读文件
    if ([path isEqualToString:@"/api/read"]) {
        NSString *file = [self resolve:[self valueOfParam:@"path" in:query] ?: @""];
        if (!file) return [self json:@{@"ok": @NO, @"error": @"路径越界"}];
        NSData *d = [NSData dataWithContentsOfFile:file];
        if (!d) return [self json:@{@"ok": @NO, @"error": @"读不到文件"}];
        if (d.length > 2 * 1024 * 1024) return [self json:@{@"ok": @NO, @"error": @"文件超过 2MB"}];
        NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"(二进制文件)";
        return [self json:@{@"ok": @YES, @"text": text, @"bytes": @(d.length)}];
    }

    // 写文件
    if ([path isEqualToString:@"/api/write"] && [method isEqualToString:@"POST"]) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if (![j isKindOfClass:NSDictionary.class]) return [self json:@{@"ok": @NO, @"error": @"请求体不是 JSON"}];
        if (![j[@"confirm"] boolValue]) return [self json:@{@"ok": @NO, @"error": @"缺少 confirm=1"}];
        NSString *file = [self resolve:j[@"path"] ?: @""];
        if (!file) return [self json:@{@"ok": @NO, @"error": @"路径越界"}];
        NSString *text = j[@"text"] ?: @"";
        NSString *backup = [file stringByAppendingString:@".sparkbak"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:file]) {
            [[NSFileManager defaultManager] removeItemAtPath:backup error:NULL];
            [[NSFileManager defaultManager] copyItemAtPath:file toPath:backup error:NULL];
        }
        BOOL ok = [text writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return [self json:@{@"ok": @(ok), @"backup": backup.lastPathComponent ?: @""}];
    }

    // 触发构建
    if ([path isEqualToString:@"/api/build"] && [method isEqualToString:@"POST"]) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        NSString *root = [self resolve:j[@"path"] ?: @""];
        if (!root) return [self json:@{@"ok": @NO, @"error": @"路径越界"}];
        SPProject *p = [SPProject projectAtPath:root error:NULL];
        if (!p) return [self json:@{@"ok": @NO, @"error": @"不是可识别的工程"}];
        SPToolchainProfile *profile = [[SPToolchain shared] localProfileWithSDK:nil error:NULL];
        if (!profile) return [self json:@{@"ok": @NO, @"error": @"工具链未就绪"}];

        NSMutableArray *logLines = [NSMutableArray array];
        [SPBuilder buildProject:p options:p.options profile:profile
                         onLine:^(NSString *line, SPLogLevel level) { [logLines addObject:line]; }
                       onFinish:^(SPJob *job) {
            NSString *text = [logLines componentsJoinedByString:@"\n"];
            [[SPStore shared] persistLogText:text jobId:job.jobId];
        }];
        return [self json:@{@"ok": @YES, @"message": @"构建已在手机上开始，稍后刷新日志"}];
    }

    // 最近构建历史
    if ([path isEqualToString:@"/api/history"]) {
        return [self json:@{@"ok": @YES, @"items": [[SPStore shared] buildHistory] ?: @[]}];
    }

    return [self json:@{@"ok": @NO, @"error": @"not found"}];
}

/// 把相对路径解析到允许的根目录下，越界返回 nil
/// 读取包内网页（Remote/index.html）；也支持从 Documents 覆盖（方便调试）
- (nullable NSData *)remoteIndexHTML {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *override = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Workbench"]
                          stringByAppendingPathComponent:@"Remote/index.html"];
    if ([fm fileExistsAtPath:override]) return [NSData dataWithContentsOfFile:override];

    NSString *inBundle = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Remote/index.html"];
    if ([fm fileExistsAtPath:inBundle]) return [NSData dataWithContentsOfFile:inBundle];
    return nil;
}

- (nullable NSString *)resolve:(NSString *)rel {
    NSString *root = self.allowedRoot.length ? self.allowedRoot : [[SPStore shared] projectsDirectory];
    // 去掉 ../ 之类
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *c in [rel componentsSeparatedByString:@"/"]) {
        if (!c.length || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."]) return nil;
        [parts addObject:c];
    }
    NSString *full = [root stringByAppendingPathComponent:[parts componentsJoinedByString:@"/"]];
    NSString *stdRoot = [root stringByStandardizingPath];
    NSString *stdFull = [full stringByStandardizingPath];
    if (![stdFull hasPrefix:stdRoot]) return nil;
    return stdFull;
}

- (NSString *)valueOfParam:(NSString *)key in:(NSString *)query {
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [pair substringToIndex:eq.location];
        if (![k isEqualToString:key]) continue;
        NSString *v = [pair substringFromIndex:eq.location + 1];
        return [v stringByRemovingPercentEncoding] ?: v;
    }
    return nil;
}

- (void)respond:(int)fd status:(NSInteger)status body:(NSString *)body {
    NSData *d = [self httpResponse:status type:@"application/json; charset=utf-8"
                              body:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [self writeAll:fd data:d];
}

- (NSData *)json:(NSDictionary *)obj {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:NULL];
    return [self httpResponse:200 type:@"application/json; charset=utf-8" body:d];
}

- (NSData *)httpResponse:(NSInteger)status type:(NSString *)type body:(NSData *)body {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n"
         "Content-Type: %@\r\n"
         "Content-Length: %lu\r\n"
         "Cache-Control: no-store\r\n"
         "Connection: close\r\n\r\n",
        (long)status, status == 200 ? @"OK" : (status == 401 ? @"Unauthorized" : @"Error"),
        type, (unsigned long)body.length];
    NSMutableData *out = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:body ?: [NSData data]];
    return out;
}

- (void)writeAll:(int)fd data:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger total = data.length, sent = 0;
    while (sent < total) {
        ssize_t n = write(fd, bytes + sent, total - sent);
        if (n <= 0) break;
        sent += (NSUInteger)n;
    }
}

@end

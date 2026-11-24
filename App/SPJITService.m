//
//  SPJITService.m
//

#import "SPJITService.h"
#import "SPToolchainInstaller.h"
#import "SPCompat.h"
#import "SPProcessGuard.h"
#import "SPSession.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <spawn.h>
#import <fcntl.h>
#import <errno.h>

extern char **environ;

@interface SPJITService ()
@property (nonatomic, assign) SPJITServiceState state;
@property (nonatomic, assign) pid_t helperPid;
@property (nonatomic, assign) int socketFd;
@property (nonatomic, copy, nullable) NSString *socketPath;
@property (nonatomic, copy, nullable) NSMutableString *logBuffer;
@end

@implementation SPJITService

+ (instancetype)shared {
    static SPJITService *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SPJITService new];
        s.state = SPJITServiceStateStopped;
        s.socketFd = -1;
        s.helperPid = -1;
        s.logBuffer = [NSMutableString string];
    });
    return s;
}

- (BOOL)isRunning { return self.state == SPJITServiceStateRunning; }

- (NSString *)statusText {
    switch (self.state) {
        case SPJITServiceStateRunning: return @"运行中";
        case SPJITServiceStateStarting: return @"启动中…";
        case SPJITServiceStateFailed: return @"启动失败（已回退主进程 JIT）";
        default: return @"未启动";
    }
}

#pragma mark - helper 路径

- (NSString *)helperPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 1) App 包内 bin/
    NSString *bundleBin = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"bin/spark-jitd"];
    [candidates addObject:bundleBin];

    // 2) 工具链目录
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    if (inst.isInstalled) {
        [candidates addObject:[inst.installRoot stringByAppendingPathComponent:@"bin/spark-jitd"]];
    }

    // 3) 常见放置位置
    [candidates addObjectsFromArray:@[
        @"/var/jb/usr/bin/spark-jitd",
        @"/usr/local/bin/spark-jitd",
    ]];

    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

#pragma mark - 启动

- (void)start {
    if (self.state == SPJITServiceStateRunning) return;

    NSString *helper = self.helperPath;
    if (!helper) {
        self.state = SPJITServiceStateFailed;
        SPLog(@"JIT 子进程：找不到 spark-jitd（可放到 Toolchain/bin）");
        return;
    }

    self.state = SPJITServiceStateStarting;
    NSString *sock = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"spark-jit-%d.sock", getpid()]];
    [[NSFileManager defaultManager] removeItemAtPath:sock error:NULL];
    self.socketPath = sock;

    // 起子进程：把 socket 路径作为参数传进去
    //
    // **不能用 /bin/sh**：iOS 沙盒里它不存在，
    // posix_spawn 会返回 ENOENT（errno=2），看起来像「文件找不到」，
    // 实际是解释器不在。用运行时自带的 bash（helpers/bash）。
    NSString *sh = [SPSession resolveShell];
    if (!sh.length) sh = @"/bin/sh";
    NSString *cmd = [NSString stringWithFormat:@"%@ '%@'", helper, sock];

    pid_t child = -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    const char *argv[] = { sh.fileSystemRepresentation, "-c", cmd.UTF8String, NULL };

    // helper 用 persona 托管（迁移自 TrollAgent CLaunch）：
    // helper 自己带 get-task-allow / platform-application，但它能不能拿到
    // 可执行内存取决于**以什么身份跑**。主 App 不是 root 时，用 persona 99
    // 单独把 helper 提到 root，主进程身份保持不变。
    // 不支持 persona 的系统上保持原样（NULL attr），不影响启动。
    posix_spawnattr_t attr;
    posix_spawnattr_t *attrPtr = NULL;
    BOOL usedPersona = NO;
    if ([[SPProcessGuard shared] personaAPIAvailable] && getuid() != 0) {
        if (posix_spawnattr_init(&attr) == 0) {
            if ([[SPProcessGuard shared] applyRootPersonaToAttr:&attr]) {
                attrPtr = &attr;
                usedPersona = YES;
            }
        }
    }

    int rc = posix_spawn(&child, sh.fileSystemRepresentation, &actions, attrPtr, (char **)argv, environ);
    if (attrPtr) posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

    // persona 打了属性却起不来（签名没带 persona-mgmt）→ 退回普通身份再试一次
    if (rc != 0 && usedPersona) {
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        rc = posix_spawn(&child, sh.fileSystemRepresentation, &actions, NULL, (char **)argv, environ);
        posix_spawn_file_actions_destroy(&actions);
        SPLog(@"[!] JIT helper persona 启动失败，已退回继承身份：%d", rc);
    }

    if (rc != 0) {
        self.state = SPJITServiceStateFailed;
        SPLog(@"JIT 子进程：posix_spawn 失败 errno=%d (%s) shell=%@ helper=%@",
              errno, strerror(errno), sh, helper);
        return;
    }
    self.helperPid = child;

    // 给 helper 一点时间 bind socket
    for (int i = 0; i < 30; i++) {
        usleep(100 * 1000);
        if ([[NSFileManager defaultManager] fileExistsAtPath:sock]) break;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:sock]) {
        self.state = SPJITServiceStateFailed;
        SPLog(@"JIT 子进程：socket 未出现（helper 可能启动失败）");
        [self stop];
        return;
    }

    self.state = SPJITServiceStateRunning;
    self.logBuffer = [NSMutableString string];
    SPLog(@"JIT 子进程已启动 pid=%d sock=%@", (int)child, sock);
}

- (void)stop {
    if (self.helperPid > 0) {
        kill(self.helperPid, SIGTERM);
        usleep(200 * 1000);
        kill(self.helperPid, SIGKILL);
        self.helperPid = -1;
    }
    if (self.socketFd >= 0) {
        close(self.socketFd);
        self.socketFd = -1;
    }
    if (self.socketPath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.socketPath error:NULL];
    }
    self.state = SPJITServiceStateStopped;
}

#pragma mark - 通信

- (NSString *)sendCommand:(NSString *)command error:(NSError **)error {
    if (self.state != SPJITServiceStateRunning) {
        if (error) *error = SPError(SPErrorCodeUnsupported, @"JIT 子进程未运行");
        return nil;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = SPError(SPErrorCodeIO, @"创建 socket 失败");
        return nil;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, self.socketPath.fileSystemRepresentation, sizeof(addr.sun_path));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        if (error) *error = SPError(SPErrorCodeIO,
            [NSString stringWithFormat:@"连接 helper 失败：%s", strerror(errno)]);
        self.state = SPJITServiceStateFailed;
        return nil;
    }

    NSString *line = [command stringByAppendingString:@"\n"];
    write(fd, line.UTF8String, line.length);

    // 读回复（单行）
    NSMutableData *buffer = [NSMutableData data];
    char chunk[1024];
    while (buffer.length < 8192) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        if (memchr(chunk, '\n', (size_t)n)) break;
    }
    close(fd);

    NSString *reply = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
    reply = [reply stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!reply.length) {
        if (error) *error = SPError(SPErrorCodeIO, @"helper 无响应");
        return nil;
    }
    return reply;
}

- (BOOL)verifyExecutableMemoryWithError:(NSError **)error {
    if (!self.isRunning) [self start];
    if (!self.isRunning) {
        if (error) *error = SPError(SPErrorCodeUnsupported, @"JIT helper 不可用");
        return NO;
    }
    NSString *reply = [self sendCommand:@"jit-check" error:error];
    return [reply.lowercaseString containsString:@"ok"];
}

@end

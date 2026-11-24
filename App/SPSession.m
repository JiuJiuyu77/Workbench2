//
//  SPSession.m
//

#import "SPSession.h"
#import "SPAOJIT.h"
#import "SPCompat.h"
#import "SPProcessGuard.h"
#import "SPToolchainInstaller.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>

extern char **environ;

#pragma mark - SPCommandResult

@implementation SPCommandResult
- (BOOL)ok { return self.exitCode == 0 && !self.cancelled && !self.timedOut && !self.launchError; }
@end

#pragma mark - SPSession

/// 记录所有活着的子进程 pid，App 退出时统一清理。
///
/// 线程安全：这个集合会被三处并发访问
///   · launch: 在调用方线程登记 pid
///   · 读线程结束后回收 pid
///   · applicationWillTerminate 在主线程遍历清理
/// 直接用 NSMutableSet 会出现「边遍历边修改」的异常
/// （Collection was mutated while being enumerated），
/// 也可能丢 pid 导致子进程清理不干净（App 退了 clang 还在跑）。
/// 所有访问都必须走下面三个带锁的入口。
static NSMutableSet<NSNumber *> *SPSessionPidSet(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void SPSessionPidAdd(pid_t pid) {
    if (pid <= 0) return;
    NSMutableSet *set = SPSessionPidSet();
    @synchronized (set) { [set addObject:@(pid)]; }
}

static void SPSessionPidRemove(pid_t pid) {
    NSMutableSet *set = SPSessionPidSet();
    @synchronized (set) { [set removeObject:@(pid)]; }
}

/// 取快照（遍历时用这个，不要在持锁状态下 kill）
static NSArray<NSNumber *> *SPSessionPidSnapshot(void) {
    NSMutableSet *set = SPSessionPidSet();
    @synchronized (set) { return set.allObjects; }
}

/// 在 applicationWillTerminate / 进入后台超时时调用：
/// 杀掉所有我们自己起的子进程组，避免 App 被杀后 clang/make 还在跑
void SPSessionReapAllChildren(void) {
    NSArray *pids = SPSessionPidSnapshot();
    for (NSNumber *n in pids) {
        pid_t p = (pid_t)n.intValue;
        kill(-p, SIGKILL);
        kill(p, SIGKILL);
    }
    @synchronized (SPSessionPidSet()) { [SPSessionPidSet() removeAllObjects]; }
    SPLog(@"已清理 %lu 个残留子进程", (unsigned long)pids.count);
}

@interface SPSession ()
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) int outFd;
@property (nonatomic, assign) int errFd;
@property (nonatomic, strong) NSMutableString *outBuf;
@property (nonatomic, strong) NSMutableString *errBuf;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) BOOL cancelRequested;
@property (nonatomic, assign) BOOL timedOut;
// 必须是 strong 而不是 copy：
// SPCommandResult 没有实现 NSCopying，用 copy 会发送 copyWithZone:
// → 找不到方法 → _copyDescription → 转发异常 → abort。
// 这就是从 v1.0.0 一直存在的「构建时闪退」的真正根因。
@property (nonatomic, strong) SPCommandResult *result;
@property (nonatomic, strong) dispatch_queue_t readQueue;
@property (nonatomic, assign) BOOL finished;
// 同步调用使用独立完成信号，不依赖主队列。
@property (nonatomic, copy) void (^internalCompletion)(SPCommandResult *);
/// AOJIT 试跑用：启动失败时不要通知完成（否则信号量提前释放，回退就废了）
@property (nonatomic, assign) BOOL suppressLaunchFailureNotify;
@end

@implementation SPSession

/// 环境变量只保留 NSString 值：其它类型（NSNull/NSNumber/嵌套）一律转成字符串，
/// 否则 copy 时会在 -forwardingTargetForSelector: 上抛异常直接 abort。
static NSDictionary<NSString *, NSString *> *SPSanitizeEnvironment(NSDictionary *env) {
    if (![env isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in env) {
        if (![key isKindOfClass:NSString.class]) continue;
        id value = env[key];
        if ([value isKindOfClass:NSString.class]) {
            out[key] = value;
        } else if ([value isKindOfClass:NSNumber.class]) {
            out[key] = [value stringValue];
        } else if (value == nil || [value isKindOfClass:NSNull.class]) {
            out[key] = @"";
        } else {
            out[key] = [value description] ?: @"";
        }
    }
    return [out copy];
}

- (instancetype)initWithEnvironment:(NSDictionary<NSString *, NSString *> *)env
                   workingDirectory:(NSString *)cwd {
    if ((self = [super init])) {
        _environment = SPSanitizeEnvironment(env);
        _workingDirectory = [cwd isKindOfClass:NSString.class] ? [cwd copy] : nil;
        _outBuf = [NSMutableString string];
        _errBuf = [NSMutableString string];
        _readQueue = dispatch_queue_create("spark.session.read", DISPATCH_QUEUE_CONCURRENT);
        _pid = -1; _outFd = -1; _errFd = -1;
    }
    return self;
}

- (BOOL)isRunning { return self.pid > 0 && !self.finished; }

- (void)setEnvironment:(NSDictionary<NSString *, NSString *> *)environment {
    _environment = SPSanitizeEnvironment(environment);
}

#pragma mark 环境组装

- (NSArray<NSString *> *)environmentStrings {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (char **e = environ; e && *e; e++) {
        NSString *kv = [NSString stringWithUTF8String:*e];
        NSRange r = [kv rangeOfString:@"="]; if (r.location == NSNotFound) continue;
        merged[[kv substringToIndex:r.location]] = [kv substringFromIndex:r.location + 1];
    }
    [merged addEntriesFromDictionary:SPSanitizeEnvironment(self.environment)];
    if (!merged[@"HOME"]) merged[@"HOME"] = NSHomeDirectory();
    if (!merged[@"LANG"]) merged[@"LANG"] = @"en_US.UTF-8";
    if (!merged[@"TERM"]) merged[@"TERM"] = @"dumb";
    // 逐个确认是 NSString —— 只要有一个非字符串，setenv/strdup 就会崩
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (id k in merged) {
        if (![k isKindOfClass:NSString.class]) continue;
        id v = merged[k];
        if ([v isKindOfClass:NSString.class]) safe[k] = v;
        else if ([v isKindOfClass:NSNumber.class]) safe[k] = [v stringValue];
        else safe[k] = @"";
    }
    return [SPUtil envPairsFromDictionary:safe];
}

#pragma mark 启动

- (int)launch:(NSString *)exe args:(NSArray<NSString *> *)args {
    if (self.isRunning) return -1;

    int pfd[2], efd[2];
    if (pipe(pfd) != 0) return -1;
    if (pipe(efd) != 0) { close(pfd[0]); close(pfd[1]); return -1; }

    pid_t child = -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, efd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pfd[0]);
    posix_spawn_file_actions_addclose(&actions, efd[0]);
    // 注意：posix_spawn_file_actions_addchdir_np 在 iOS 上不可用（SDK 标记为 unavailable），
    // 所以工作目录统一在 runShell 里用 `cd` 完成，这里不再处理。

    // 会话独立，方便整组 kill
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&attr, 0);
    sigset_t defs; sigemptyset(&defs); sigaddset(&defs, SIGPIPE);
    posix_spawnattr_setsigdefault(&attr, &defs);

    // 子进程身份：请求 root persona 时才动属性。
    // 失败不影响启动 —— 继续用继承身份跑，只是没有 root 权限。
    if (self.childIdentity == SPChildIdentityRootPersona) {
        [[SPProcessGuard shared] applyRootPersonaToAttr:&attr];
    }

    // argv
    NSMutableArray *argvArr = [NSMutableArray arrayWithObject:exe];
    [argvArr addObjectsFromArray:args];
    char **argv = calloc(argvArr.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argvArr.count; i++) {
        id a = argvArr[i];
        const char *cstr = [a isKindOfClass:NSString.class] ? [(NSString *)a UTF8String] : "";
        argv[i] = strdup(cstr ? cstr : "");
    }
    argv[argvArr.count] = NULL;

    NSArray *envArr = [self environmentStrings];
    char **envp = calloc(envArr.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envArr.count; i++) {
        id a = envArr[i];
        const char *cstr = [a isKindOfClass:NSString.class] ? [(NSString *)a UTF8String] : "";
        envp[i] = strdup(cstr ? cstr : "");
    }
    envp[envArr.count] = NULL;

    int rc = posix_spawn(&child, exe.fileSystemRepresentation, &actions, &attr, argv, envp);
    int savedErrno = rc; // posix_spawn 直接返回错误码，不保证设置 errno

    // persona 兜底重试：有些设备上符号存在但签名没带 persona-mgmt，
    // 打了 persona 属性反而让 spawn 直接失败（通常是 EPERM/EINVAL）。
    // 这时必须退回「不带 persona」再起一次，否则本来能跑的编译会莫名其妙起不来。
    // 只重试一次，且只在确实请求了 persona 时。
    if (rc != 0 && self.childIdentity == SPChildIdentityRootPersona) {
        posix_spawnattr_t plain;
        posix_spawnattr_init(&plain);
        posix_spawnattr_setflags(&plain, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF);
        posix_spawnattr_setpgroup(&plain, 0);
        sigset_t d2; sigemptyset(&d2); sigaddset(&d2, SIGPIPE);
        posix_spawnattr_setsigdefault(&plain, &d2);

        int rc2 = posix_spawn(&child, exe.fileSystemRepresentation, &actions, &plain, argv, envp);
        posix_spawnattr_destroy(&plain);

        SPLog(@"[!] persona spawn 失败(%d)，已退回继承身份重试：%d", rc, rc2);
        if (rc2 == 0) {
            rc = 0;
        } else {
            savedErrno = rc2;
        }
    }

    for (NSUInteger i = 0; i < argvArr.count; i++) free(argv[i]);
    free(argv);
    for (NSUInteger i = 0; i < envArr.count; i++) free(envp[i]);
    free(envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);

    close(pfd[1]); close(efd[1]);

    if (rc != 0) {
        close(pfd[0]); close(efd[0]);
        SPCommandResult *r = [SPCommandResult new];
        r.exitCode = -1;
        r.launchError = SPError(SPErrorCodeLaunchFailed,
            [NSString stringWithFormat:@"无法启动 %@：%s", exe.lastPathComponent, strerror(savedErrno)]);
        self.result = r;
        if (self.suppressLaunchFailureNotify) return -1;   // AOJIT 试跑：交给调用方回退
        [self finishNotifying];
        return -1;
    }

    self.pid = child;
    SPSessionPidAdd(child);   // 登记，供退出时清理
    self.outFd = pfd[0];
    self.errFd = efd[0];
    self.startTime = [NSDate date];
    self.finished = NO;
    [self.outBuf setString:@""];
    [self.errBuf setString:@""];

    [self beginReading];
    return child;
}

- (void)beginReading {
    __weak typeof(self) weakSelf = self;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_async(group, self.readQueue, ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        [self pumpFd:self.outFd level:SPLogLevelOut buffer:self.outBuf];
    });
    dispatch_group_async(group, self.readQueue, ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        [self pumpFd:self.errFd level:SPLogLevelErr buffer:self.errBuf];
    });

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        int status = 0;
        pid_t w = 0;
        // 子进程可能还没退出（读端 EOF ≈ 进程已关闭 fd，通常已退出）
        do { w = waitpid(self.pid, &status, 0); } while (w < 0 && errno == EINTR);
        int code = -1;
        if (w == self.pid) {
            if (WIFEXITED(status)) code = WEXITSTATUS(status);
            else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
        }
        SPSessionPidRemove(self.pid);
        self.pid = -1;
        [self completeWithExitCode:code];
    });

    // 超时处理
    if (self.timeout > 0) {
        NSTimeInterval t = self.timeout;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && self.isRunning) { self.timedOut = YES; [self cancel]; }
        });
    }
}

- (void)pumpFd:(int)fd level:(SPLogLevel)level buffer:(NSMutableString *)buffer {
    char chunk[4096];
    NSMutableData *pending = [NSMutableData data];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n > 0) {
            [pending appendBytes:chunk length:(NSUInteger)n];
            // 按行切分
            const char *bytes = pending.bytes;
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < pending.length; i++) {
                if (bytes[i] == '\n') {
                    NSData *lineData = [pending subdataWithRange:NSMakeRange(start, i - start)];
                    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                    if (!line) line = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
                    [self emitLine:line ?: @"" level:level buffer:buffer];
                    start = i + 1;
                }
            }
            if (start > 0) [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            continue;
        }
        if (n == 0) break;
        if (errno == EINTR) continue;
        break;
    }
    if (pending.length) {
        NSString *tail = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
        if (!tail) tail = [[NSString alloc] initWithData:pending encoding:NSISOLatin1StringEncoding];
        [self emitLine:tail ?: @"" level:level buffer:buffer];
    }
    close(fd);
    if (fd == self.outFd) self.outFd = -1; else if (fd == self.errFd) self.errFd = -1;
}

- (void)emitLine:(NSString *)line level:(SPLogLevel)level buffer:(NSMutableString *)buffer {
    @synchronized (buffer) {
        [buffer appendString:line]; [buffer appendString:@"\n"];
        if (buffer.length > 4 * 1024 * 1024) { // 防止超大输出吃光内存
            [buffer deleteCharactersInRange:NSMakeRange(0, buffer.length - 2 * 1024 * 1024)];
        }
    }
    void (^cb)(NSString *, SPLogLevel) = self.onLine;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 主队列 block 里抛的异常无法被外层捕获：
            // libdispatch 会直接 std::terminate → abort，栈里只有
            // libdispatch/_ZSt9terminatev，完全看不出是谁抛的。
            // 这里兜住并落盘，至少能知道异常名与原因。
            @try {
                cb(line, level);
            } @catch (NSException *e) {
                SPLog(@"[!] onLine 回调异常 %@: %@\n%@", e.name, e.reason,
                      [e.callStackSymbols componentsJoinedByString:@"\n"]);
            }
        });
    }
}

- (void)completeWithExitCode:(int)code {
    if (self.finished) return;
    self.finished = YES;
    SPCommandResult *r = self.result ?: [SPCommandResult new];
    r.exitCode = code;
    r.elapsed = -[self.startTime timeIntervalSinceNow];
    @synchronized (self.outBuf) { r.stdoutText = [self.outBuf copy]; }
    @synchronized (self.errBuf) { r.stderrText = [self.errBuf copy]; }
    r.cancelled = self.cancelRequested;
    r.timedOut = self.timedOut;
    if (!r.launchError && !r.cancelled && code != 0) {
        r.launchError = nil; // 非零退出不当作启动错误
    }
    self.result = r;
    [self finishNotifying];
}

- (void)finishNotifying {
    void (^internal)(SPCommandResult *) = self.internalCompletion;
    self.internalCompletion = nil;
    if (internal) internal(self.result);
    void (^cb)(SPCommandResult *) = self.onFinish;
    SPCommandResult *r = self.result;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                cb(r);
            } @catch (NSException *e) {
                // 同上：主队列里抛异常会直接 abort，这里是唯一能记下来的地方
                SPLog(@"[!] onFinish 回调异常 %@: %@\n%@", e.name, e.reason,
                      [e.callStackSymbols componentsJoinedByString:@"\n"]);
            }
        });
    }
}

#pragma mark 公开入口

/// 找一个能真正执行的 shell —— 这是「退出码 -1」最常见的原因。
///
/// iOS 沙盒里 /bin/sh 往往 isExecutableFileAtPath 返回 YES 但 posix_spawn
/// 仍失败（沙盒规则拦截 /bin 下的系统二进制），于是子进程根本没起来，
/// 退出码就是 -1、耗时 0 秒 —— 与「编译失败」看起来完全一样。
///
/// 优先级：
///   1. 运行时自带的 bash（tools/helpers/bash 或 usr/bin/bash）
///   2. 运行时 usr/bin 下的 bash / sh
///   3. /var/jb/bin/sh（越狱）
///   4. /bin/sh（最后才试）
+ (NSString *)resolveShell {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSString *> *cands = [NSMutableArray array];

        // App 包内的 helpers。
        // **平铺布局优先**（与 Rein 一致）：Workbench.app/helpers/bash。
        // 旧布局是 Workbench.app/Toolchain/helpers/bash，一并保留兼容。
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        [cands addObject:[bundle stringByAppendingPathComponent:@"helpers/bash"]];
        [cands addObject:[bundle stringByAppendingPathComponent:@"helpers/sh"]];
        [cands addObject:[bundle stringByAppendingPathComponent:@"Toolchain/helpers/bash"]];
        [cands addObject:[bundle stringByAppendingPathComponent:@"Toolchain/helpers/sh"]];
        // 也看 theos-root 下的 bin（有些包把 sh 放这里）
        [cands addObject:[bundle stringByAppendingPathComponent:@"theos-root/usr/bin/bash"]];

        // 工具链安装目录
        SPToolchainInstaller *inst = [SPToolchainInstaller shared];
        NSString *root = inst.installRoot;
        [cands addObject:[root stringByAppendingPathComponent:@"helpers/bash"]];
        [cands addObject:[root stringByAppendingPathComponent:@"usr/bin/bash"]];
        [cands addObject:[root stringByAppendingPathComponent:@"bin/bash"]];
        [cands addObject:[root stringByAppendingPathComponent:@"helpers/sh"]];
        [cands addObject:[root stringByAppendingPathComponent:@"usr/bin/sh"]];

        // 越狱 / 系统兜底
        [cands addObject:@"/var/jb/bin/sh"];
        [cands addObject:@"/bin/sh"];
        [cands addObject:@"/usr/bin/sh"];

        for (NSString *c in cands) {
            if ([fm isExecutableFileAtPath:c]) { cached = c; break; }
        }
        if (!cached) cached = @"/bin/sh";
        SPLog(@"使用 shell：%@", cached);
    });
    return cached;
}

- (int)runShell:(NSString *)script {
    NSString *sh = [SPSession resolveShell];

    // posix_spawn 在 iOS 上没有可用的 chdir，改在脚本前面拼一句 cd；
    // exec 失败时 cd 也失败，脚本会立刻以非 0 退出，语义一样。
    NSString *body = script ?: @"";
    if (self.workingDirectory.length) {
        NSString *quoted = [self.workingDirectory stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        body = [NSString stringWithFormat:@"cd '%@' || exit 200\n%@", quoted, body];
    }
    // AOJIT：无工作目录的「单行简单命令」跳过 /bin/sh 直接 exec。
    // 命中才走；任何可疑语法或解析失败都会返回 nil，自动回落 sh（语义不变）。
    if (!self.workingDirectory.length) {
        NSArray<NSArray<NSString *> *> *stages =
            [[SPAOJIT shared] directStagesForScript:body environment:self.environment];
        if (stages.count) {
            if (stages.count == 1) {
                // 单命令：走 launch:（失败可回退）
                NSArray<NSString *> *argv = stages.firstObject;
                NSArray<NSString *> *rest = argv.count > 1
                    ? [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)]
                    : @[];
                self.suppressLaunchFailureNotify = YES;
                int rc = [self launch:argv[0] args:rest];
                self.suppressLaunchFailureNotify = NO;
                if (rc > 0) {
                    [[SPAOJIT shared] noteDirectSpawn];
                    return rc;
                }
                self.finished = NO;
                self.result = nil;
            } else {
                // 管道：多进程直连，省掉 sh 的逐段解析
                int rc = [self runPipeline:stages];
                if (rc > 0) {
                    [[SPAOJIT shared] noteDirectSpawn];
                    return rc;
                }
                self.finished = NO;
                self.result = nil;
                self.pid = -1;
            }
        }
    }

    return [self launch:sh args:@[@"-c", body]];
}

- (int)runExecutable:(NSString *)exe arguments:(NSArray<NSString *> *)args {
    return [self launch:exe args:args ?: @[]];
}

#pragma mark - 管道直执行（AOJIT 用）

- (int)runPipeline:(NSArray<NSArray<NSString *> *> *)stages {
    if (self.isRunning) return -1;
    if (!stages.count) return -1;

    NSUInteger n = stages.count;
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];

    int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
    if (pipe(outPipe) != 0) return -1;
    if (pipe(errPipe) != 0) { close(outPipe[0]); close(outPipe[1]); return -1; }

    int prevRead = -1;   // 上一段的读端（作为本段 stdin）
    int rc = 0;

    for (NSUInteger i = 0; i < n; i++) {
        NSArray<NSString *> *argvList = stages[i];
        if (!argvList.count) { rc = -1; break; }

        int nextPipe[2] = {-1, -1};
        BOOL isLast = (i == n - 1);
        if (!isLast && pipe(nextPipe) != 0) { rc = -1; break; }

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);

        // stdin
        if (prevRead >= 0) {
            posix_spawn_file_actions_adddup2(&actions, prevRead, STDIN_FILENO);
            posix_spawn_file_actions_addclose(&actions, prevRead);
        }
        // stdout
        if (isLast) {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
        } else {
            posix_spawn_file_actions_adddup2(&actions, nextPipe[1], STDOUT_FILENO);
            posix_spawn_file_actions_addclose(&actions, nextPipe[0]);
        }
        if (!isLast) posix_spawn_file_actions_addclose(&actions, nextPipe[1]);
        posix_spawn_file_actions_addclose(&actions, outPipe[0]);
        posix_spawn_file_actions_addclose(&actions, errPipe[0]);
        // stderr：所有段共用
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, errPipe[1]);

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF);
        posix_spawnattr_setpgroup(&attr, 0);
        sigset_t defs; sigemptyset(&defs); sigaddset(&defs, SIGPIPE);
        posix_spawnattr_setsigdefault(&attr, &defs);
        if (self.childIdentity == SPChildIdentityRootPersona) {
            [[SPProcessGuard shared] applyRootPersonaToAttr:&attr];
        }

        char **argv = calloc(argvList.count + 1, sizeof(char *));
        for (NSUInteger k = 0; k < argvList.count; k++) {
            NSString *a = argvList[k];
            argv[k] = strdup([a isKindOfClass:NSString.class] ? a.UTF8String : "");
        }
        argv[argvList.count] = NULL;

        NSArray *envArr = [self environmentStrings];
        char **envp = calloc(envArr.count + 1, sizeof(char *));
        for (NSUInteger k = 0; k < envArr.count; k++) {
            NSString *a = envArr[k];
            envp[k] = strdup([a isKindOfClass:NSString.class] ? a.UTF8String : "");
        }
        envp[envArr.count] = NULL;

        pid_t child = -1;
        NSString *exe = argvList[0];
        rc = posix_spawn(&child, exe.fileSystemRepresentation, &actions, &attr, argv, envp);

        for (NSUInteger k = 0; k < argvList.count; k++) free(argv[k]);
        free(argv);
        for (NSUInteger k = 0; k < envArr.count; k++) free(envp[k]);
        free(envp);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);

        if (prevRead >= 0) close(prevRead);
        if (!isLast) close(nextPipe[1]);
        prevRead = isLast ? -1 : nextPipe[0];

        if (rc != 0) { break; }
        [pids addObject:@(child)];
        SPSessionPidAdd(child);
    }

    close(outPipe[1]);
    close(errPipe[1]);
    if (prevRead >= 0) close(prevRead);

    if (rc != 0 || !pids.count) {
        for (NSNumber *p in pids) {
            kill(-p.intValue, SIGKILL); kill(p.intValue, SIGKILL);
            SPSessionPidRemove(p.intValue);
        }
        close(outPipe[0]); close(errPipe[0]);
        return -1;
    }

    self.pid = pids.lastObject.intValue;
    self.outFd = outPipe[0];
    self.errFd = errPipe[0];
    self.startTime = [NSDate date];
    self.finished = NO;
    [self.outBuf setString:@""];
    [self.errBuf setString:@""];

    __weak typeof(self) weakSelf = self;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, self.readQueue, ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        [self pumpFd:self.outFd level:SPLogLevelOut buffer:self.outBuf];
    });
    dispatch_group_async(group, self.readQueue, ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        [self pumpFd:self.errFd level:SPLogLevelErr buffer:self.errBuf];
    });

    NSArray<NSNumber *> *allPids = [pids copy];
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        int lastCode = -1;
        for (NSNumber *p in allPids) {
            int status = 0; pid_t w = 0;
            do { w = waitpid(p.intValue, &status, 0); } while (w < 0 && errno == EINTR);
            if (w == p.intValue) {
                if (WIFEXITED(status)) lastCode = WEXITSTATUS(status);
                else if (WIFSIGNALED(status)) lastCode = 128 + WTERMSIG(status);
            }
            SPSessionPidRemove(p.intValue);
        }
        self.pid = -1;
        [self completeWithExitCode:lastCode];
    });

    if (self.timeout > 0) {
        NSTimeInterval t = self.timeout;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && self.isRunning) { self.timedOut = YES; [self cancel]; }
        });
    }

    return self.pid;
}

- (void)cancel {
    self.cancelRequested = YES;
    pid_t p = self.pid;
    if (p <= 0) return;
    // 整组终止：先 TERM 再 KILL
    kill(-p, SIGTERM);
    kill(p, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (p > 0) { kill(-p, SIGKILL); kill(p, SIGKILL); }
    });
}

#pragma mark 同步便捷

+ (SPCommandResult *)runSyncShell:(NSString *)script
                      environment:(NSDictionary<NSString *, NSString *> *)env
                              cwd:(NSString *)cwd
                          timeout:(NSTimeInterval)timeout {
    // **主线程防护**
    // 这个方法会同步等待子进程结束（超时最长 180 秒）。
    // 从主线程调用会直接把界面卡死 —— 表现为「点了没反应 / 像崩溃」。
    // 与挂载模块的 sync* 系列保持同一策略：主线程调用直接拒绝，
    // 而不是让 App 假死。
    if ([NSThread isMainThread]) {
        SPLog(@"[!] runSyncShell 在主线程调用，已拒绝（会卡死界面）：%.60s",
              script.UTF8String ?: "");
        SPCommandResult *r = [SPCommandResult new];
        r.exitCode = -1;
        r.stderrText = @"内部错误：同步 Shell 不能在主线程调用";
        return r;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SPCommandResult *res = nil;
    SPSession *s = [[SPSession alloc] initWithEnvironment:env workingDirectory:cwd];
    s.timeout = timeout;
    // internalCompletion 不走主队列（见 startReading / finishNotifying），
    // 所以这里等信号量不会和主队列互相等待。
    s.internalCompletion = ^(SPCommandResult *r) { res = r; dispatch_semaphore_signal(sem); };
    [s runShell:script];

    // 主线程上同步等待依然会卡界面（虽然不会死锁）。
    // 调用方应放到后台队列；这里给一条明确警告，方便排查「界面卡住」。
    if (NSThread.isMainThread) {
        SPLog(@"[!] runSyncShell 在主线程上执行（最长 %.0fs），界面会卡住。"
              @"调用方应改到后台队列。", timeout > 0 ? timeout : 60);
    }

    // 不能永久等待：
    // 如果进程启动失败、或 onFinish 因为任何原因没被调用，
    // DISPATCH_TIME_FOREVER 会让调用线程（通常是主线程）永久卡死。
    // 这里给一个「超时 + 10 秒」的硬上限，超时就返回失败结果并杀掉会话。
    NSTimeInterval cap = (timeout > 0 ? timeout : 60) + 10;
    long waited = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cap * NSEC_PER_SEC)));

    if (waited != 0) {
        SPLog(@"[!] runSyncShell 等待超时（%.0fs），强制取消", cap);
        [s cancel];
        SPCommandResult *r = [SPCommandResult new];
        r.exitCode = -1;
        r.timedOut = YES;
        r.launchError = SPError(SPErrorCodeTimeout,
            [NSString stringWithFormat:@"命令 %.0f 秒内未完成", cap]);
        return r;
    }
    return res ?: [SPCommandResult new];
}

@end

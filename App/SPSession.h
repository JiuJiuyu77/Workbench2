//
//  SPSession.h
//  Workbench —— 一次 shell / make 调用的封装：异步、可取消、逐行回调。
//  刻意不用 NSTask（iOS 上不可用），而是 posix_spawn + 管道。
//

#import <Foundation/Foundation.h>
#import "SPModels.h"
#import "SPProcessGuard.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPCommandResult : NSObject
@property (nonatomic, assign) NSInteger exitCode;
@property (nonatomic, assign) NSTimeInterval elapsed;
@property (nonatomic, copy) NSString *stdoutText;
@property (nonatomic, copy) NSString *stderrText;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL timedOut;
@property (nonatomic, strong) NSError *launchError;
- (BOOL)ok;
@end

@interface SPSession : NSObject

/// 每读到一行就回调（主线程）
@property (nonatomic, copy, nullable) void (^onLine)(NSString *line, SPLogLevel level);
/// 结束回调（主线程）
@property (nonatomic, copy, nullable) void (^onFinish)(SPCommandResult *result);

/// 运行时的环境变量（在系统环境基础上覆盖）
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
/// 工作目录
@property (nonatomic, copy, nullable) NSString *workingDirectory;
/// 超时（秒），0 = 不限
@property (nonatomic, assign) NSTimeInterval timeout;

/// 子进程身份策略（默认继承当前身份）。
/// 设为 SPChildIdentityRootPersona 时，若系统支持 persona 私有 API，
/// 子进程会以 root persona 运行，而**父进程身份不变**。
/// 不支持时自动退回继承，不会导致启动失败。
@property (nonatomic, assign) SPChildIdentity childIdentity;

- (instancetype)initWithEnvironment:(NSDictionary<NSString *, NSString *> *)env
                   workingDirectory:(nullable NSString *)cwd;

/// 在 /bin/sh -c 下执行一串命令（会做 PATH 前缀拼接）
/// 返回的 NSString 是本次任务的 pid 组 id（便于取消）
/// 当前可用的 shell 路径（优先运行时自带 bash，其次 /var/jb/bin/sh，最后 /bin/sh）。
/// iOS 沙盒常拒绝执行 /bin/sh，选错会表现为 posix_spawn 失败（退出码 -1）。
+ (NSString *)resolveShell;

- (int)runShell:(NSString *)script;
/// 直接 exec 一个可执行文件（不经 shell），args 不含 argv[0]
- (int)runExecutable:(NSString *)exe arguments:(NSArray<NSString *> *)args;

/// 取消（先 SIGTERM，1s 后 SIGKILL，整组）
- (void)cancel;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 同步便捷方法：跑完再返回（主要用于探测版本、ls 之类）
+ (SPCommandResult *)runSyncShell:(NSString *)script
                      environment:(nullable NSDictionary<NSString *, NSString *> *)env
                              cwd:(nullable NSString *)cwd
                          timeout:(NSTimeInterval)timeout;

@end

/// 清理所有仍在运行的子进程（App 退出 / 长时间挂起时调用）
FOUNDATION_EXPORT void SPSessionReapAllChildren(void);

NS_ASSUME_NONNULL_END

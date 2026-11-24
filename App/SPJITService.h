//
//  SPJITService.h
//  Workbench —— JIT 子进程
//
//  为什么需要子进程：
//   · 主 App 即使有 no-sandbox，也未必拿到 CS_DEBUGGED，mmap(PROT_EXEC) 常被拦
//   · 越狱/TrollStore 设备上，launchd 能按 root 启动我们自带的 helper，
//     它带 get-task-allow + platform-application，能直接分配可执行内存
//   · 主 App 通过 unix socket 让 helper 做「编译/执行」这类需要 JIT 的活
//
//  启动方式（按优先级）：
//   1. 直接 posix_spawn 包内 bin/spark-jitd（TrollStore 下 uid 0 可执行）
//   2. 已装到 Documents/Workbench/Toolchain/bin 的 helper
//  失败就退回主进程内的 SPJIT（mmap 尝试）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPJITServiceState) {
    SPJITServiceStateStopped = 0,
    SPJITServiceStateStarting,
    SPJITServiceStateRunning,
    SPJITServiceStateFailed,
};

@interface SPJITService : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) SPJITServiceState state;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) NSString *statusText;

/// helper 可执行文件路径（包内或工具链里）
@property (nonatomic, readonly, nullable) NSString *helperPath;

/// helper 进程 pid（-1 表示未启动）
@property (nonatomic, readonly) pid_t helperPid;

/// 启动 helper
- (void)start;

/// 停止
- (void)stop;

/// 发一条命令给 helper，返回它的回复（同步，超时 5 秒）
- (nullable NSString *)sendCommand:(NSString *)command error:(NSError *_Nullable *_Nullable)error;

/// 让 helper 分配一块可执行内存并回报地址（用于验证 JIT 真的可用）
- (BOOL)verifyExecutableMemoryWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

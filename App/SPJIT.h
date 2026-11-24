//
//  SPJIT.h
//  Workbench —— JIT 加速
//
//  两条路，按设备能力自动挑：
//   1. 越狱/TrollStore 设备：调用 jetsam / JIT 相关 entitlement 已是平台级，
//      直接 mmap(PROT_EXEC) 就能分配可执行内存（不需要额外处理）
//   2. 普通签名的设备：需要 W^X 例外 —— 给可执行页打上
//      CS_DEBUGGED（attach 后自动具备），或使用 JIT 授权
//
//  本模块做的事：
//   · 启动时探测「JIT 是否可用」并记到设置里
//   · 提供一个可复用的可执行内存池（给需要 JIT 的场景，如正则/脚本引擎）
//   · UI 上显示当前 JIT 状态（设置 → 显示与反馈 → JIT 加速）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPJIT : NSObject

+ (instancetype)shared;

/// 当前是否具备 JIT 能力
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;

/// 上次探测时间
@property (nonatomic, readonly, strong, nullable) NSDate *lastProbe;

/// 探测结果的一句话说明
@property (nonatomic, readonly) NSString *statusText;

/// 是否在 TrollStore / 越狱环境（有平台权限）
@property (nonatomic, readonly) BOOL isPlatformApp;

/// 本次 JIT 是否由子进程提供（NO 表示主进程 mmap）
@property (nonatomic, readonly) BOOL viaSubprocess;

/// 启动时调用：异步拉起 helper 并探测
- (void)startServiceIfNeeded;

/// 主动探测（会实际申请一小块可执行内存再释放）
- (void)probe;

/// 真实执行验证：申请一页、写入 arm64 的 `ret` 指令、清 icache、真的跳进去调用一次。
/// 迁移自 TrollAgent 的 jit-check —— 只证明「能 mmap 出 PROT_EXEC」是不够的，
/// 有些签名下 mmap 会成功但一执行就 SIGKILL（缺 CS_DEBUGGED / allow-jit），
/// 必须真的跑一条指令才能确认 JIT 可用。
/// 注意：这条路径有崩溃风险，只应在探测（用户主动/启动后台）时调用，不要放进热路径。
/// @return YES 表示写入的指令被成功执行并正常返回
- (BOOL)verifyExecutableByCalling;

/// 申请一块可执行内存（失败返回 NULL）
- (nullable void *)allocateExecutable:(size_t)size;

/// 释放
- (void)freeExecutable:(void *)ptr size:(size_t)size;

/// 打开/关闭「JIT 加速」开关（关闭后只用解释执行，用于排查崩溃）
@property (nonatomic, assign) BOOL userEnabled;

@end

NS_ASSUME_NONNULL_END

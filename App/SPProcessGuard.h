//
//  SPProcessGuard.h
//  Workbench —— 运行时进程守护与身份托管
//
//  迁移自 TrollAgent 的运行时做法（CLaunch/launch.c + boot.js 守护逻辑），
//  只取与 Workbench「真跑 make / 起子进程」相关的部分：
//
//  1. persona 托管 spawn
//     TrollAgent 起 HUD 子进程时用 posix_spawnattr_set_persona_np(99) +
//     _uid_np(0)/_gid_np(0)，让子进程直接以 root persona 运行。
//     这套私有 API 在 iOS SDK 的 .tbd 里没有导出，静态链接会 undefined，
//     所以必须 dlsym 运行时取（TrollAgent 注释里写得很明确）。
//
//     Workbench 现状：靠主进程 setuid(0) 后子进程继承。
//     问题：主进程一旦不是 root（例如被 TrollStore 覆盖安装后丢了权限），
//     所有子进程都跟着非 root，编译满屏 Permission denied，且无从补救。
//     persona 方式可以在**父进程保持原身份**的前提下，单独让子进程以 root 跑。
//
//  2. 父进程守护自毁
//     TrollAgent 的 boot.js 每 2 秒检查 process.ppid !== ORIG_PPID 就 exit(0)。
//     Workbench 目前只有 applicationWillTerminate 里 SPSessionReapAllChildren()，
//     但 App 被系统直接杀掉（OOM / 用户上划）时**不会**走 willTerminate，
//     clang/make 就成了孤儿进程继续吃 CPU 和电量。
//     这里用一条 pthread 定时检查 getppid()，发现父进程变了就自杀。
//
//  与 TrollAgent 的差异（刻意为之）：
//   · 不复制它的 C 层，按 Workbench 的 ObjC 风格重写
//   · 不做 URL scheme 拉起、不碰注入，只处理「本进程起的子进程」
//   · 默认全部关闭，由调用方显式启用（避免改变现有构建语义）
//

#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// 子进程身份策略
typedef NS_ENUM(NSInteger, SPChildIdentity) {
    /// 继承当前进程身份（原有行为，默认）
    SPChildIdentityInherit = 0,
    /// 尝试用 persona 99 以 root 运行；不可用时自动退回继承
    SPChildIdentityRootPersona,
};

@interface SPProcessGuard : NSObject

+ (instancetype)shared;

#pragma mark - persona 托管 spawn

/// 当前设备/签名是否支持 persona 托管 spawn。
/// 判据是私有符号能否 dlsym 到 —— 拿不到就说明系统不提供，直接退回继承身份。
@property (nonatomic, readonly) BOOL personaAPIAvailable;

/// 上一次 persona spawn 的详细结果（设置页 / 自检页展示）
@property (nonatomic, copy, readonly) NSString *personaStatusText;

/// 推荐给新会话使用的子进程身份。
/// 规则：当前进程不是 root、且 persona 私有 API 可用 → 用 root persona；
/// 否则继承（已是 root 时子进程本来就继承 root，没必要多打一层属性）。
/// 这是给 SPSession 填 childIdentity 的默认值，调用方仍可自行覆盖。
@property (nonatomic, readonly) SPChildIdentity preferredIdentity;

/// 给 posix_spawnattr_t 打上 persona 属性。
/// 必须在 posix_spawnattr_init 之后、posix_spawn 之前调用。
/// @return YES 表示属性已生效；NO 表示不支持（调用方继续用原属性即可，不影响启动）
- (BOOL)applyRootPersonaToAttr:(void *)attr;

#pragma mark - 父进程守护

/// 启动守护线程。父进程消失后自动给本进程发 SIGKILL。
/// 幂等：重复调用不会起多条线程。
/// @param interval 检查间隔（秒），建议 2.0（与 TrollAgent 一致）
- (void)startParentWatchdogWithInterval:(NSTimeInterval)interval;

/// 停止守护（测试 / 排查时用）
- (void)stopParentWatchdog;

/// 守护是否在运行
@property (nonatomic, readonly) BOOL watchdogRunning;

/// 记录下来的原始父进程 pid（守护判据）
@property (nonatomic, readonly) pid_t originalParentPid;

@end

NS_ASSUME_NONNULL_END

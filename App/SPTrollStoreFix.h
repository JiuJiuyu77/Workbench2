//
//  SPTrollStoreFix.h
//  Workbench —— TrollStore 安装态自检与修复入口
//
//  背景
//  ----
//  覆盖安装时，TrollStore 有时不会重新赋予 App root 能力，
//  进程以 euid=501 启动。典型症状：
//    · setuid(0) 返回 EPERM（即使 ipa 的 entitlements 完全正确）
//    · MTLCreateSystemDefaultDevice() 返回 nil
//    · posix_spawn 起的子进程立刻失败
//  用户看到的是「编译失败」，很难联想到安装方式。
//
//  做法
//  ----
//  在设置页放一个自检入口，直接告诉用户当前是什么状态、
//  以及一句话能怎么修。不做任何降级或绕过。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPTrollStoreState) {
    SPTrollStoreStateOK = 0,        // 以 root 运行，一切正常
    SPTrollStoreStateNotRoot,       // 非 root，但签名里带了 platform-application
    SPTrollStoreStateNoEntitlement, // 签名里就没有 platform-application（构建/签名问题）
};

@interface SPTrollStoreFix : NSObject

/// 当前安装态
+ (SPTrollStoreState)state;

/// 一句话说明（设置页副标题）
+ (NSString *)statusText;

/// 详细诊断（点进去看）
+ (NSString *)diagnosticDetail;

/// 弹出修复引导
+ (void)presentGuideFrom:(UIViewController *)host;

/// 尝试用 TrollStore 的 URL scheme 唤起它
+ (BOOL)openTrollStore;

/// 本 App 的 entitlements 里是否有 platform-application
+ (BOOL)hasPlatformEntitlement;

#pragma mark - JIT 授权（TrollStore 外部附加）

/// 系统是否注册了 TrollStore 的 JIT 授权 URL（apple-magnifier://enable-jit）
+ (BOOL)canRequestJITAuthorization;

/// 唤起 TrollStore 的「允许 JIT」开关。
/// 机制（同 TrollAgent FAQ）：iOS 不允许进程同步调试自己，必须由 TrollStore 的
/// root helper 从外部 attach 本进程，内核才允许 MAP_JIT 内存真正可执行。
/// 返回 NO 表示本机没有 TrollStore（或未注册该 scheme），调用方应退回主进程探测。
+ (BOOL)requestJITAuthorization;

/// 给用户看的 JIT 授权说明
+ (NSString *)jitAuthorizationHint;

@end

NS_ASSUME_NONNULL_END

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

@end

NS_ASSUME_NONNULL_END

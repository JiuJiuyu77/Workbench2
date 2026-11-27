//
//  SPTrollStoreFix.m
//

#import "SPTrollStoreFix.h"
#import "SPCompat.h"
#import <Security/Security.h>

// SecTask 是 Security.framework 的私有 API（TrollStore 生态普遍使用）。
// 公开 SDK 里没有声明，这里自己声明一下。
// 用途：读取**当前进程自身**的 entitlements，判断签名里有没有
// platform-application —— 比对外部工具跑 codesign 快得多，也不需要子进程。
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

@implementation SPTrollStoreFix

/// 读取自身 entitlements 里的 platform-application。
/// SecTask API 不需要特殊权限，未签名/无该键时返回 NO。
+ (BOOL)hasPlatformEntitlement {
    static BOOL cached = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task) return;
        CFTypeRef v = SecTaskCopyValueForEntitlement(task, CFSTR("platform-application"), NULL);
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
                cached = CFBooleanGetValue((CFBooleanRef)v);
            }
            CFRelease(v);
        }
        CFRelease(task);
    });
    return cached;
}

+ (SPTrollStoreState)state {
    if (getuid() == 0) return SPTrollStoreStateOK;
    // 非 root：区分「签名本身没有」还是「签名有但没生效」
    return [self hasPlatformEntitlement] ? SPTrollStoreStateNotRoot
                                         : SPTrollStoreStateNoEntitlement;
}

+ (NSString *)statusText {
    switch ([self state]) {
        case SPTrollStoreStateOK:
            return @"root（uid 0）· 功能完整";
        case SPTrollStoreStateNotRoot:
            return [NSString stringWithFormat:@"非 root（uid %d）· 建议重新安装", (int)getuid()];
        case SPTrollStoreStateNoEntitlement:
            return @"签名缺少平台权限 · 需重新签名安装";
    }
}

+ (NSString *)diagnosticDetail {
    SPTrollStoreState st = [self state];
    NSMutableString *m = [NSMutableString string];

    [m appendFormat:@"进程 uid：%d\n", (int)getuid()];
    [m appendFormat:@"platform-application：%@\n",
        [self hasPlatformEntitlement] ? @"有" : @"无"];

    switch (st) {
        case SPTrollStoreStateOK:
            [m appendString:@"\n状态正常：子进程会以 root 运行，编译、注入、签名都可用。"];
            break;

        case SPTrollStoreStateNotRoot:
            [m appendString:
                @"\n诊断：ipa 的签名是正确的（带 platform-application），"
                 "但进程仍以普通用户启动。\n\n"
                 "这几乎总是**覆盖安装**导致的 —— TrollStore 沿用了旧的"
                 "注册记录，没有重新赋予 root 能力。\n\n"
                 "解决办法：\n"
                 @"1. 在 TrollStore 里先「卸载」Workbench，再全新安装 ipa\n"
                 @"2. 或在 TrollStore 里对本 App 点「重新注册 / Reinstall」\n"
                 @"3. 装完重启一次设备更稳妥"];
            break;

        case SPTrollStoreStateNoEntitlement:
            [m appendString:
                @"\n诊断：当前可执行文件里读取不到 platform-application。\n\n"
                 "可能是：\n"
                 @"• 用自签工具（Sideloadly / AltStore）安装，签名被替换\n"
                 @"• 通过 Xcode 直接调试安装\n\n"
                 "请用 TrollStore 安装官方发布的 ipa。"];
            break;
    }
    return m;
}

+ (BOOL)openTrollStore {
    // TrollStore 的 URL scheme 在不同版本间有差异，按可能性依次尝试。
    NSArray<NSString *> *schemes = @[@"apple-magnifier://", @"trollstore://"];
    for (NSString *s in schemes) {
        NSURL *u = [NSURL URLWithString:s];
        if (u && [UIApplication.sharedApplication canOpenURL:u]) {
            [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
            SPLog(@"已唤起 TrollStore");
            return YES;
        }
    }
    return NO;
}

+ (void)presentGuideFrom:(UIViewController *)host {
    if ([self state] == SPTrollStoreStateOK) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"运行环境正常"
            message:[self diagnosticDetail] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"运行环境需要修复"
        message:[self diagnosticDetail] preferredStyle:UIAlertControllerStyleActionSheet];

    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"apple-magnifier://"]] ||
        [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"trollstore://"]]) {
        [a addAction:[UIAlertAction actionWithTitle:@"打开 TrollStore 重新安装"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [self openTrollStore]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"复制诊断信息"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = [self diagnosticDetail];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要锚点
    if (a.popoverPresentationController) {
        a.popoverPresentationController.sourceView = host.view;
        a.popoverPresentationController.sourceRect = CGRectMake(
            CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
    }
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - JIT 授权（TrollStore 外部附加）

// TrollStore 的 JIT 开关 URL。TrollStore 在 Info.plist 里注册了
// apple-magnifier scheme，路径 enable-jit 由 RootHelper 处理：
// 它从外部对本进程做 PT_ATTACHEXC / PT_DETACH，内核才真正放行 MAP_JIT。
// 仅当 App 自己拿不到可执行内存时才用这条路（见 SPJIT）。
static NSString *const kSPEnableJITURL = @"apple-magnifier://enable-jit";

+ (BOOL)canRequestTrollStoreJIT {
    return [self canRequestJITAuthorization];
}

+ (BOOL)canRequestJITAuthorization {
    NSURL *url = [NSURL URLWithString:kSPEnableJITURL];
    return url && [UIApplication.sharedApplication canOpenURL:url];
}

+ (BOOL)requestJITAuthorization {
    NSURL *url = [NSURL URLWithString:kSPEnableJITURL];
    if (!url || ![UIApplication.sharedApplication canOpenURL:url]) {
        SPLog(@"JIT 授权：系统未注册 apple-magnifier://enable-jit（非 TrollStore 安装）");
        return NO;
    }
    SPLog(@"JIT 授权：唤起 TrollStore enable-jit");
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {
        SPLog(@"JIT 授权：TrollStore 回调 ok=%d", ok);
    }];
    return YES;
}

+ (NSString *)jitAuthorizationHint {
    if ([self canRequestJITAuthorization]) {
        return @"点一下「授权 JIT」，TrollStore 会从外部给本 App 附加调试权限；"
                "回到 App 后会自动重新探测。开发者模式需保持开启。";
    }
    return @"本机没有可用的 TrollStore JIT 授权入口：\n"
            "• 用 TrollStore 安装官方 ipa 后此入口才会出现；\n"
            "• 越狱环境可直接用 ldid -S 签名并开启 get-task-allow；\n"
            "• 其它安装方式下 JIT 只能退回主进程 mmap 探测（部分设备会被内核拒绝）。";
}

@end

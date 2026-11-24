//
//  SPToolchain.h
//  Workbench —— 工具链发现与构建环境组装。
//
//  行为完全对齐 Rein：按「用户设置 → 安装目录 → 设备上的 Rein 目录」优先级探测，
//  找到什么就用什么，找不到的来源在 UI 里标红并给出修复建议。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPToolchainComponent) {
    SPToolchainComponentTheos = 0,   // make + makefiles + Logos
    SPToolchainComponentSDK,         // iPhoneOS*.sdk
    SPToolchainComponentDarwin,      // clang/ld64/ldid/strip/ar（真机可执行）
    SPToolchainComponentOLLVM,       // Arkari LLVM 混淆编译器
    SPToolchainComponentReverse,     // radare2 / mt-macho / mt-inject-dylib
    SPToolchainComponentPython,      // python3
    SPToolchainComponentNode,        // node / pnpm
    SPToolchainComponentDevices,     // ssh/scp（远程编译）
    SPToolchainComponentSwift,       // swiftc 编译器（iOS 上极罕见）
    SPToolchainComponentCount
};

/// 远端/本地编译目标
typedef NS_ENUM(NSInteger, SPBuildTarget) {
    SPBuildTargetDevice = 0,   // 在本机直接跑 make（Rein 里的「真机编译」）
    SPBuildTargetRemote,       // 通过 ssh 在另一台越狱设备上 make
    SPBuildTargetCI,           // 推到 GitHub 走 Actions
};

/// 一份「实际生效的」工具链路径集合。字段都可能为 nil，用 usable 判断。
@interface SPToolchainProfile : NSObject

@property (nonatomic, copy) NSString *name;                 // "本机" / "远程 iPhone" / "GitHub CI"
@property (nonatomic, assign) SPBuildTarget target;

@property (nonatomic, copy, nullable) NSString *theosPath;      // THEOS
@property (nonatomic, copy, nullable) NSString *sdkPath;        // 选中的 SDK 绝对路径
@property (nonatomic, copy) NSString *sdkName;                  // "iPhoneOS16.5.sdk"
@property (nonatomic, copy, nullable) NSString *darwinBinDir;   // clang/ld64/ldid 目录
@property (nonatomic, copy, nullable) NSString *ollvmRoot;      // OLLVM 根（含 bin/clang）
@property (nonatomic, copy, nullable) NSString *reverseBinDir;  // radare2 等目录
@property (nonatomic, copy, nullable) NSString *python3;
@property (nonatomic, copy, nullable) NSString *node;
@property (nonatomic, copy, nullable) NSString *sshHost;        // 远程
@property (nonatomic, copy, nullable) NSString *sshUser;
@property (nonatomic, assign) NSInteger sshPort;

/// 生成传给 make / 子进程的环境变量（不含 PATH 拼接，PATH 由 SPSession 另算）
- (NSDictionary<NSString *, NSString *> *)extraEnvironment;

@end

#pragma mark - 工具链扫描结果

@interface SPToolchainScan : NSObject
/// 每个组件是否找到
- (BOOL)has:(SPToolchainComponent)c;
/// 某个组件对应的人类可读路径（找不到时给空字符串）
- (NSString *)pathFor:(SPToolchainComponent)c;
/// 简短状态描述，例如 "Theos ✓  iPhoneOS17.0.sdk ✓  OLLVM ✗"
- (NSString *)summary;
/// 缺失组件的修复建议
- (NSArray<NSString *> *)remedies;
@end

@interface SPToolchain : NSObject

/// 单例，扫描是懒加载 + 可刷新
+ (instancetype)shared;

/// 自动发现 Rein / DSH.app 的运行时根目录（找不到返回 nil）
+ (nullable NSString *)discoverReinRoot;

/// 探测根目录（按优先级）：用户设置的安装目录、Rein 目录、App 包内
@property (nonatomic, copy) NSString *reinRoot;      // 外部 Theos 根目录（可选，内置运行时优先）
@property (nonatomic, copy, nullable) NSString *homeRoot; // 用户自定义安装目录

- (void)rescan;

/// 距上次扫描超过 minInterval 秒才真正重扫（避免每次刷新列表都全包扫一遍）。
/// 返回 YES 表示这次真的扫了。
- (BOOL)rescanIfStale:(NSTimeInterval)minInterval;

/// 上次扫描的时间戳（0 表示从未扫过）
@property (nonatomic) NSTimeInterval lastScanTime;

@property (nonatomic, readonly) SPToolchainScan *scan;

/// 可用 SDK 名列表（"iPhoneOS16.5.sdk" ...）。默认只返回**完整**的。
- (NSArray<NSString *> *)availableSDKs;
/// 同上，可选择是否带上不完整的（界面需要展示「已停用」时用）
- (NSArray<NSString *> *)availableSDKsIncludingIncomplete:(BOOL)includeIncomplete;
/// 所有候选 SDK 目录（优先级从高到低）
- (NSArray<NSString *> *)sdkDirectories;
/// SDK 是否完整可用（SDKSettings.json + usr/include）
- (BOOL)sdkDirectoryIsComplete:(NSString *)sdkPath;
/// 按名字解析 SDK 绝对路径
- (nullable NSString *)sdkPathForName:(nullable NSString *)name;

/// 组装本机 profile。sdkName 为 nil 时择优；失败返回 nil 并填充 error。
- (nullable SPToolchainProfile *)localProfileWithSDK:(nullable NSString *)sdkName
                                              error:(NSError *_Nullable *_Nullable)error;

/// 远程 profile（只有 ssh 配置，用于远程构建）
- (SPToolchainProfile *)remoteProfileWithHost:(NSString *)host
                                         user:(NSString *)user
                                         port:(NSInteger)port
                                          sdk:(nullable NSString *)sdkName;

/// CI profile：命令在 macOS runner 上执行，本地只负责打包上传
- (SPToolchainProfile *)ciProfileWithSDK:(nullable NSString *)sdkName;

/// 直接把 PATH 前缀（Darwin bin + theos bin + 系统目录）拼出来
- (NSString *)pathPrefixForProfile:(SPToolchainProfile *)profile;

@end

/// 内置工具链的 bin 目录（未安装时返回空串）
FOUNDATION_EXPORT NSString *SPToolchainInstallerBinDir(void);

NS_ASSUME_NONNULL_END

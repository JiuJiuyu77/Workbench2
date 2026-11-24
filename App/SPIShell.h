//
//  SPIShell.h
//  Workbench —— iSH（Alpine Linux）集成
//
//  为什么需要它：
//   iOS 自带的 BSD 工具很残缺 —— 没有 GNU sed/awk/grep 的很多用法，
//   没有 python3、没有 node、没有真正的包管理。
//   而 Theos 的很多构建脚本默认按 Linux 环境写（`sed -i` 无后缀、
//   `grep -P`、`tar --strip-components` 等），在 BSD 上会直接报错。
//
//  集成方式：**调用 iSH 的 CLI**，不内嵌终端。
//    · 只借用它的 Linux 用户态工具补齐命令缺口
//    · 编译、链接、签名仍走 Workbench 自己的 Darwin 工具链
//      （clang-16 / ld64 / ldid 必须在 Darwin 侧跑，Linux 侧跑不了）
//
//  设备上没装 iSH 时，所有接口返回「不可用」，调用方自动跳过。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPIShellState) {
    SPIShellStateUnknown = 0,
    SPIShellStateAvailable,     // 找到 iSH 且能执行命令
    SPIShellStateNotInstalled,  // 没装
    SPIShellStateUnusable,      // 装了但调不通（首次启动未完成初始化等）
};

@interface SPIShell : NSObject

+ (instancetype)shared;

/// iSH 是否可用（会做一次真实调用验证，结果缓存）
@property (nonatomic, readonly) SPIShellState state;

/// 解析到的 iSH 可执行入口（形如 .../iSH.app/ish 或 run.sh）
@property (nonatomic, readonly, nullable) NSString *executablePath;

/// 检测（可强制重新检测）。completion 在主线程回调。
- (void)probeForce:(BOOL)force completion:(void (^)(SPIShellState state, NSString *detail))completion;

/// 在 iSH 里执行一条命令，返回输出。不可用时 completion 给 nil + 错误。
- (void)runCommand:(NSString *)command
            timeout:(NSTimeInterval)timeout
         completion:(void (^)(BOOL ok, NSString *_Nullable output, NSError *_Nullable error))completion;

/// 同步版本，仅用于后台线程
- (nullable NSString *)runCommandSync:(NSString *)command
                              timeout:(NSTimeInterval)timeout
                                error:(NSError *_Nullable *_Nullable)error;

/// 当前可在 iSH 侧使用的工具（探测一次，用于能力展示）
- (NSArray<NSString *> *)availableTools;

/// 生成用于构建脚本的环境前缀：iSH 可用时把它的 bin 放到 PATH 末尾，
/// 让 BSD 缺失的命令回落到 Linux 版。不可用时返回空串。
/// @param prefer 优先尝试的目录列表（iSH 侧路径）
- (NSString *)pathFallbackSnippet;

@end

NS_ASSUME_NONNULL_END

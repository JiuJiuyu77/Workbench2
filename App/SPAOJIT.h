//
//  SPAOJIT.h
//  Workbench —— AOJIT：预编译 Shell 执行计划
//
//  为什么需要它：
//   每次 `runShell:` 都要先 posix_spawn 一个 /bin/sh，让 sh 逐字符解析脚本、
//   展开引号、查 PATH，然后才 exec 真正的程序。对 `ls -l` 这种简单命令，
//   sh 自身启动 + 解析通常比命令本身还慢（实测 10–30ms）。
//
//  AOJIT 做的事（类比「预先录制并编译好，不再逐条解释」）：
//   1. 录制：第一次见到某个脚本时，判断它是否是「无 shell 语法的简单命令」；
//      是则把它拆成 argv，并把命令名解析成绝对路径，缓存下来。
//   2. 回放：下次同一脚本直接命中缓存，跳过 /bin/sh，直接 posix_spawn 目标二进制。
//   3. PATH 解析结果也单独缓存，避免每次遍历 PATH 目录。
//
//  安全边界（重要）：
//   · 只有**完全不含** shell 元字符（| & ; < > $ ` ( ) * ? [ ] { } ~ ! \\ ' \" 换行）的脚本
//     才走 AOJIT；否则一律回落 sh —— 语义必须与原来完全一致。
//   · 不做任何字符串改写、不做变量展开、不做通配符展开。
//   · 关闭开关后零开销：直接返回 nil，调用方走原路径。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPAOJIT : NSObject

+ (instancetype)shared;

/// 总开关（默认开启）。关闭后 directArgvForScript: 立即返回 nil。
@property (nonatomic, assign) BOOL userEnabled;

/// 命中/未命中统计（用于设置页展示「省了多少次 sh 启动」）
@property (nonatomic, readonly) NSUInteger hitCount;
@property (nonatomic, readonly) NSUInteger missCount;
@property (nonatomic, readonly) NSUInteger directSpawnCount;

/// 一句话状态，给设置页用
@property (nonatomic, readonly) NSString *statusText;

/// 清空录制缓存与计数
- (void)reset;

/// 尝试把脚本编译成可直接 exec 的 argv。
/// @param script 原始脚本（不含 cd 前缀，由调用方处理）
/// @param env    本次执行的环境（用其中的 PATH 解析命令名）
/// @return argv（argv[0] 为可执行文件绝对路径）；无法走 AOJIT 时返回 nil。
- (nullable NSArray<NSString *> *)directArgvForScript:(NSString *)script
                                          environment:(nullable NSDictionary<NSString *, NSString *> *)env;

/// 管道版本：把 `a | b | c` 编译成多段 argv（每段 argv[0] 为绝对路径）。
/// 仅当每一段都是「无 shell 语法的简单命令」且都能解析到绝对路径时返回；
/// 否则返回 nil（调用方回落 sh，语义保持不变）。
- (nullable NSArray<NSArray<NSString *> *> *)directStagesForScript:(NSString *)script
                                                       environment:(nullable NSDictionary<NSString *, NSString *> *)env;

/// 调用方在真正以 argv 直接 spawn 成功后调用，累加 directSpawnCount
- (void)noteDirectSpawn;

@end

NS_ASSUME_NONNULL_END

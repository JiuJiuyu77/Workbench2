//
//  SPDiagnostics.h
//  Workbench —— 构建与运行风险诊断（参考 Dylix 的 RuntimeDiagnostics 思路）
//
//  与「编译失败诊断」不同，这里回答的是「这一版做出来能不能用」：
//   · 二进制索引：架构 / 依赖库 / 是否含签名
//   · 构建溯源：用了哪些源文件、什么选项、什么时候编的
//   · 运行时风险：目标系统版本、架构缺失、依赖了私有框架、
//     tweak 没写过滤（会注入所有进程）、rootless 装到 rootful 设备等
//   · strip 建议：release 是否该剥符号
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPRiskLevel) {
    SPRiskLevelInfo = 0,
    SPRiskLevelWarn,
    SPRiskLevelError,
};

@interface SPRiskItem : NSObject
@property (nonatomic, assign) SPRiskLevel level;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy, nullable) NSString *suggestion;
@end

@interface SPDiagnostics : NSObject

/// 读取 Mach-O 的基础信息（架构、类型、依赖、是否签名）
+ (NSDictionary *)binaryIndexForPath:(NSString *)binaryPath;

/// 构建溯源：源文件清单 + 选项 + 时间
+ (NSDictionary *)buildProvenanceForProject:(NSString *)projectPath;

/// 运行时风险扫描
+ (NSArray<SPRiskItem *> *)runtimeRisksForProject:(NSString *)projectPath;

/// release 是否应该 strip
+ (BOOL)shouldStripForProject:(NSString *)projectPath;

/// 生成一份完整诊断报告（JSON 可序列化）
+ (NSDictionary *)reportForProject:(NSString *)projectPath binary:(nullable NSString *)binaryPath;

@end

NS_ASSUME_NONNULL_END

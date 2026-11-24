//
//  SPHeaderExport.h
//  Workbench —— 从 IPA 导出 Objective-C 头文件（参考 Dylix 的「IPA 头文件导出」）
//
//  做法：Mach-O 里的 __objc_classname / __objc_methname 段列出来，
//  按 class 分组生成 @interface 声明。这不是「还原源码」，
//  只能看有哪些类、哪些方法，签名只能按 sel 猜。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPHeaderExport : NSObject

/// 分析一个 IPA 或 .app 目录里的主二进制，返回生成的 headers 文本
/// 目录结构：<输出目录>/<类名>.h + all.h
+ (void)exportHeadersFromApp:(NSString *)appPath
                  outputDir:(NSString *)outputDir
                   progress:(nullable void (^)(NSString *status))progress
                 completion:(void (^)(BOOL ok, NSInteger classCount, NSError *_Nullable error))completion;

/// 同步版本：只取原始 objc 元数据（类名 + 方法名），给逆向页用
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)objcClassesAndMethodsInBinary:(NSString *)binaryPath
                                                                           error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

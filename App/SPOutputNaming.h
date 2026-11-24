//
//  SPOutputNaming.h
//  Workbench —— 产物命名模板（参考 Dylix 的 OutputNaming）
//
//  默认 Theos 产出的名字是 <name>_<version>_<arch>.deb，但用户常有自己习惯：
//    com.foo.bar_1.0.0_iphoneos-arm.deb
//    Foo-1.0.0-arm64.tipa
//  iOS 插件开发者圈子里还常用：
//    {name}_{version}_{packageArch}
//
//  这里给一套模板 + 实时预览，避免改完才发现名字不对。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPOutputNaming : NSObject

/// 可用占位符（用于 UI 展示）
+ (NSArray<NSString *> *)availablePlaceholders;

/// 每种产物的默认模板
+ (NSString *)defaultPatternForExtension:(NSString *)ext;   // deb / tipa / app / dylib

/// 用上下文渲染模板
/// 支持的占位符：
///   {name}        产品名（Tweak_NAME / APPLICATION_NAME）
///   {version}     CFBundleShortVersionString 或 control 的 Version
///   {build}       CFBundleVersion
///   {arch}        arm64 / arm64e / arm64 arm64e
///   {packageArch} iphoneos-arm / iphoneos-arm64
///   {scheme}      rootful / rootless / roothide
///   {bundleId}    com.example.foo
///   {date}        yyyyMMdd
///   {time}        HHmmss
+ (NSString *)renderPattern:(NSString *)pattern
                      context:(NSDictionary<NSString *, NSString *> *)context;

/// 从工程目录推断上下文（读 Makefile / control）
+ (NSDictionary<NSString *, NSString *> *)contextForProject:(NSString *)projectPath;

/// 校验模板：包含未知占位符时返回错误描述，合法返回 nil
+ (nullable NSString *)validatePattern:(NSString *)pattern;

@end

NS_ASSUME_NONNULL_END

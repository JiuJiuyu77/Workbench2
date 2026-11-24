//
//  WorkbenchHealth.h
//  Workbench —— 构建环境自检
//
//  参考 Rein 系工具（v3.1.0）的自检形态：分项检查、每项给出
//  「通过 / 失败 + 具体细节 + 修复建议」，而不是只抛一句构建失败。
//
//  与 v3.1.0 的区别（重要）：
//    v3.1.0 检查的是 Theos 工具链（clang-16 / ld64 / ldid / make / perl）；
//    Workbench 走进程内 LLVM（clang.xcframework + lld.xcframework）+ Xcode SDK，
//    没有 clang-16 / ld64 / make 这些外部二进制。
//    所以这里检查的是**本工程真实依赖**，照抄 v3.1.0 只会全部误报。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WBHealthLevel) {
    WBHealthLevelOK = 0,
    WBHealthLevelWarn,
    WBHealthLevelFail,
};

@interface WBHealthItem : NSObject
@property (nonatomic, copy) NSString *identifier;   // 稳定 id，便于统计
@property (nonatomic, copy) NSString *title;        // 人类可读名称
@property (nonatomic, assign) WBHealthLevel level;
@property (nonatomic, copy) NSString *detail;       // 实测到什么
@property (nonatomic, copy, nullable) NSString *hint;   // 失败时怎么办
+ (instancetype)item:(NSString *)identifier
               title:(NSString *)title
               level:(WBHealthLevel)level
              detail:(NSString *)detail
                hint:(nullable NSString *)hint;
- (NSString *)levelText;
@end

@interface WBHealthReport : NSObject
@property (nonatomic, copy) NSArray<WBHealthItem *> *items;
@property (nonatomic, readonly) BOOL ok;            // 无 Fail 项
@property (nonatomic, readonly) NSUInteger failCount;
@property (nonatomic, readonly) NSUInteger warnCount;
- (NSString *)summary;                              // 一行总述，便于显示在设置行
- (NSString *)plainText;                            // 多行文本，便于复制/导出
@end

@interface WBHealth : NSObject

/// 同步跑全部检查（内部只做文件系统探测，不含编译，通常 < 50ms）
+ (WBHealthReport *)runChecks;

/// App 资源根目录（bundle 内）
+ (NSString *)resourceRoot;

@end

/// 自检界面（列表展示，点击行查看修复建议）
UIViewController *WBHealthController(void);

NS_ASSUME_NONNULL_END

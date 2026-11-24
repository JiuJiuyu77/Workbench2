//
//  SPToolchainDownloader.h
//  Workbench —— 可选工具组件的按需下载
//
//  ipa 只内置 CORE（Theos + 最小编译链）。
//  OLLVM / radare2 / 完整工具集 太大，放进 Release 附件，用户点一下再下。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 可下载的组件
typedef NS_ENUM(NSInteger, SPComponent) {
    SPComponentCoreTools = 0,   // git / curl / jq / rg
    SPComponentReverse,         // radare2 / mt-macho
    SPComponentNode,            // Node 24.5.0
    SPComponentBuildTools,      // CMake + Ninja
    SPComponentPython,          // Python 3.13
    SPComponentTheos,           // 完整 Theos（不再含 SDK）
    SPComponentOLLVM,           // Arkari LLVM 23.1.1
    SPComponentSDK17,           // iPhoneOS17.0.sdk（按需下载）
    SPComponentSDK26,           // iPhoneOS26.5.sdk（按需下载）
    SPComponentCount,
};

@interface SPComponentInfo : NSObject
@property (nonatomic, assign) SPComponent component;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, assign) unsigned long long approxSize;
@property (nonatomic, readonly, getter=isInstalled) BOOL installed;
@end

@interface SPToolchainDownloader : NSObject

+ (instancetype)shared;

/// 所有组件状态
- (NSArray<SPComponentInfo *> *)components;

/// 刷新安装状态
- (void)reload;

/// 下载并展开某个组件（进度回调主线程）
- (void)download:(SPComponent)component
        progress:(nullable void (^)(CGFloat fraction, NSString *status))progress
      completion:(void (^)(BOOL ok, NSError *_Nullable error))completion;

/// 删除已下载组件
- (void)remove:(SPComponent)component;

/// 组件安装目录：Documents/Workbench/Toolchain/<子目录>
- (NSString *)directoryFor:(SPComponent)component;

/// 下载源（默认 GitHub Release，可在设置里覆盖）
@property (nonatomic, copy) NSString *baseURL;

@end

NS_ASSUME_NONNULL_END

//
//  WBTheosToolsController.h
//  Workbench —— Theos 工具链管理（dylix 界面风格）
//
//  能力来自 Work1 的 SPToolchain / SPToolchainInstaller / SPToolchainDownloader，
//  界面按 dylix 的 Studio 风格重写，不使用 Work1 的 Storyboard/自定义视图。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 工具链管理页。传入的 host 用于返回时定位导航控制器（可为 nil）
UIViewController *WBTheosToolsController(void);

NS_ASSUME_NONNULL_END

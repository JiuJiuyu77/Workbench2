//
//  WBCloudBuild.h
//  Workbench —— GitHub Actions 云端构建
//
//  补齐 Workbench 1（Spark/Rein 血统）的「云端构建」能力：
//   · 在仓库里写入 .github/workflows/workbench-cloudbuild.yml（Theos 工程）
//   · 用 workflow_dispatch 触发构建
//   · 轮询最近一次运行的状态 / 结论 / 日志地址
//
//  设计边界：
//   · 只用公开 REST API（api.github.com），不依赖自建 Worker；
//   · token 取自已有的 Git 凭据（TMCGitService credentialForURL:），
//     本模块不落盘、不打印 token；
//   · 只读状态 + 触发构建，不代替用户在电脑上改工程。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WBCloudBuildState) {
    WBCloudBuildStateUnknown = 0,
    WBCloudBuildStateQueued,
    WBCloudBuildStateInProgress,
    WBCloudBuildStateSuccess,
    WBCloudBuildStateFailure,
};

@interface WBCloudBuild : NSObject

/// 工作流文件名（写入 .github/workflows/ 下）
@property (class, nonatomic, readonly) NSString *workflowFileName;

/// 仓库 slug（owner/name），持久化在 NSUserDefaults
@property (class, nonatomic, copy, nullable) NSString *repository;

/// 分支 / tag，默认 main
@property (class, nonatomic, copy) NSString *reference;

/// 是否为 rootless 包（传给 workflow 的 scheme 输入）
@property (class, nonatomic, assign) BOOL rootless;

/// 生成 Theos 工程的云端构建 workflow 内容
+ (NSString *)workflowYAML;

/// 把 workflow 写进仓库（已存在且内容相同时直接成功）
+ (void)installWorkflowWithToken:(NSString *)token
                      completion:(void (^)(NSString *_Nullable message, NSError *_Nullable error))completion;

/// 触发 workflow_dispatch
+ (void)dispatchWithToken:(NSString *)token
               completion:(void (^)(NSError *_Nullable error))completion;

/// 查询最近一次运行
+ (void)latestRunWithToken:(NSString *)token
                completion:(void (^)(NSDictionary *_Nullable run, NSError *_Nullable error))completion;

/// 运行状态 → 中文
+ (NSString *)describeRun:(nullable NSDictionary *)run;

/// 运行状态 → 枚举
+ (WBCloudBuildState)stateOfRun:(nullable NSDictionary *)run;

/// 从本机 Git 凭据里取 GitHub token（没有则返回 nil）
+ (nullable NSString *)savedToken;

@end

NS_ASSUME_NONNULL_END

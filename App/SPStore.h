//
//  SPStore.h
//  Workbench —— 本地持久化（JSON 文件，放在 Documents/Workbench 下）
//

#import <Foundation/Foundation.h>
#import "SPModels.h"
#import "SPToolchain.h"

NS_ASSUME_NONNULL_BEGIN

/// 全局设置
@interface SPSettings : NSObject <NSCopying>

@property (nonatomic, copy) NSString *projectsRoot;        // 默认 Documents/Workbench/projects
@property (nonatomic, copy) NSString *defaultSDK;
@property (nonatomic, assign) SPBuildTarget defaultTarget;
@property (nonatomic, copy, nullable) NSString *sshHost;
@property (nonatomic, copy, nullable) NSString *sshUser;
@property (nonatomic, assign) NSInteger sshPort;
@property (nonatomic, copy, nullable) NSString *sshKeyPath;
@property (nonatomic, copy, nullable) NSString *githubRepo;   // owner/name
@property (nonatomic, copy, nullable) NSString *githubBranch;
@property (nonatomic, assign) BOOL keepScreenOn;
@property (nonatomic, assign) BOOL hapticsOnBuildDone;
@property (nonatomic, assign) NSInteger maxLogLines;
@property (nonatomic, assign) BOOL showCommandPreview;

/// 产物命名模板（参考 Dylix 的 OutputNaming）
/// 空 = 用 Theos 默认命名。占位符见 SPOutputNaming.availablePlaceholders
@property (nonatomic, copy, nullable) NSString *outputPattern;

/// 编译前自动 git 快照（参考 Dylix 的 GitAutomation）
@property (nonatomic, assign) BOOL autoSnapshotBeforeBuild;
/// 快照提交用的作者信息（空则用 Workbench 默认值）
@property (nonatomic, copy, nullable) NSString *gitUserName;
@property (nonatomic, copy, nullable) NSString *gitUserEmail;

@property (nonatomic, copy, nullable) NSString *sshPassword; // 存于 Keychain，此处仅内存使用

+ (instancetype)shared;
- (void)save;

@end

/// 最近项目 / 构建历史 / 工具链扫描缓存
@interface SPStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *baseDirectory;

/// 最近打开的项目（SPProject 的最小快照，路径 + 选项 + 时间）
- (NSArray<NSDictionary *> *)recentProjects;
- (void)pushRecentProject:(SPProject *)project;
- (void)removeRecentProjectAtPath:(NSString *)path;

/// 构建历史（按时间倒序，最多保留 N 条）
- (NSArray<NSDictionary *> *)buildHistory;
- (void)appendBuildRecord:(SPJob *)job;

/// 每个项目的选项持久化：<base>/options/<hash>.json
- (SPBuildOptions *)optionsForProjectPath:(NSString *)path;
- (void)saveOptions:(SPBuildOptions *)options forProjectPath:(NSString *)path;

/// 常用路径
- (NSString *)projectsDirectory;
- (NSString *)artifactsDirectory;
- (NSString *)logsDirectory;
- (NSString *)archivesDirectory;
/// 收件箱：用户从文件 App 导入的 dylib/deb/zip/ipa
- (NSString *)inboxDirectory;
/// 用户导入的 iPhoneOS SDK 存放处
- (NSString *)sdksDirectory;
/// 编辑快照：<base>/snapshots/<文件名哈希>/<时间戳>.bak
- (NSString *)snapshotsDirectory;

/// 为即将写入的文本做一次快照（返回快照路径；同内容不重复备份，返回 nil）
- (nullable NSString *)snapshotFileAtPath:(NSString *)path newText:(nullable NSString *)newText;
/// 某文件的快照列表（新→旧）：@{@"path":…, @"date":…, @"size":…}
- (NSArray<NSDictionary *> *)snapshotsForFile:(NSString *)path;
/// 读回某个快照的文本
- (nullable NSString *)readSnapshotAtPath:(NSString *)snapshotPath;
/// 清掉某文件的全部快照（可选保留最近 keep 个）
- (void)pruneSnapshotsForFile:(NSString *)path keep:(NSInteger)keep;

/// 把字符串写进日志文件，返回路径
- (nullable NSString *)persistLogText:(NSString *)text jobId:(NSString *)jobId;

@end

NS_ASSUME_NONNULL_END

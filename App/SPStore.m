//
//  SPStore.m
//

#import "SPStore.h"
#import "SPCompat.h"
#import "SPModels.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark - SPSettings

@interface SPSettings ()
@property (nonatomic, copy) NSString *filePath;
@end

@implementation SPSettings

+ (instancetype)shared {
    static SPSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SPSettings new];
        s.projectsRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Workbench/projects"];
        s.defaultSDK = @"";
        s.defaultTarget = SPBuildTargetDevice;
        s.sshUser = @"mobile";
        s.sshPort = 22;
        s.githubBranch = @"main";
        s.keepScreenOn = YES;
        s.hapticsOnBuildDone = YES;
        s.maxLogLines = 5000;
        s.showCommandPreview = YES;
        s.autoSnapshotBeforeBuild = YES;
        s.filePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Workbench/settings.json"];
        [s load];
    });
    return s;
}

- (void)load {
    NSData *d = [NSData dataWithContentsOfFile:self.filePath];
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![j isKindOfClass:NSDictionary.class]) return;
    if (j[@"projectsRoot"]) self.projectsRoot = j[@"projectsRoot"];
    if (j[@"defaultSDK"]) self.defaultSDK = j[@"defaultSDK"];
    if (j[@"defaultTarget"]) self.defaultTarget = [j[@"defaultTarget"] integerValue];
    if (j[@"sshHost"]) self.sshHost = j[@"sshHost"];
    if (j[@"sshUser"]) self.sshUser = j[@"sshUser"];
    if (j[@"sshPort"]) self.sshPort = [j[@"sshPort"] integerValue];
    if (j[@"sshKeyPath"]) self.sshKeyPath = j[@"sshKeyPath"];
    if (j[@"githubRepo"]) self.githubRepo = j[@"githubRepo"];
    if (j[@"githubBranch"]) self.githubBranch = j[@"githubBranch"];
    if (j[@"keepScreenOn"]) self.keepScreenOn = [j[@"keepScreenOn"] boolValue];
    if (j[@"haptics"]) self.hapticsOnBuildDone = [j[@"haptics"] boolValue];
    if (j[@"maxLogLines"]) self.maxLogLines = [j[@"maxLogLines"] integerValue];
    if (j[@"showCommandPreview"]) self.showCommandPreview = [j[@"showCommandPreview"] boolValue];
}

- (id)copyWithZone:(NSZone *)zone { return self; } // 单例配置不需要真拷贝

- (void)save {
    NSDictionary *j = @{
        @"projectsRoot": self.projectsRoot ?: @"",
        @"defaultSDK": self.defaultSDK ?: @"",
        @"defaultTarget": @(self.defaultTarget),
        @"sshHost": self.sshHost ?: @"", @"sshUser": self.sshUser ?: @"",
        @"sshPort": @(self.sshPort), @"sshKeyPath": self.sshKeyPath ?: @"",
        @"githubRepo": self.githubRepo ?: @"", @"githubBranch": self.githubBranch ?: @"",
        @"keepScreenOn": @(self.keepScreenOn), @"haptics": @(self.hapticsOnBuildDone),
        @"maxLogLines": @(self.maxLogLines), @"showCommandPreview": @(self.showCommandPreview),
    };
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.filePath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:NULL];
    [d writeToFile:self.filePath atomically:YES];
}

@end

#pragma mark - SPStore

@interface SPStore ()
@property (nonatomic, copy) NSString *base;
- (NSString *)hashOfPath:(NSString *)path;
- (NSString *)snapshotDirForFile:(NSString *)path;
@end

@implementation SPStore

+ (instancetype)shared {
    static SPStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SPStore new];
        s.base = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Workbench"];
        [s prepare];
    });
    return s;
}

- (NSString *)baseDirectory { return self.base; }

- (void)prepare {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sub in @[@"", @"projects", @"artifacts", @"logs", @"archives", @"options", @"inbox", @"SDKs"]) {
        [fm createDirectoryAtPath:[self.base stringByAppendingPathComponent:sub]
      withIntermediateDirectories:YES attributes:nil error:NULL];
    }
}

- (NSString *)projectsDirectory { return [self.base stringByAppendingPathComponent:@"projects"]; }
- (NSString *)artifactsDirectory { return [self.base stringByAppendingPathComponent:@"artifacts"]; }
- (NSString *)logsDirectory { return [self.base stringByAppendingPathComponent:@"logs"]; }
- (NSString *)archivesDirectory { return [self.base stringByAppendingPathComponent:@"archives"]; }
- (NSString *)inboxDirectory { return [self.base stringByAppendingPathComponent:@"inbox"]; }
- (NSString *)sdksDirectory { return [self.base stringByAppendingPathComponent:@"SDKs"]; }

#pragma mark 编辑快照（保存前自动备份，可回滚）

- (NSString *)snapshotsDirectory {
    return [self.base stringByAppendingPathComponent:@"snapshots"];
}

/// 每个文件一个子目录：snapshots/<路径哈希>/<时间戳>.bak
- (NSString *)snapshotDirForFile:(NSString *)path {
    NSString *h = [self hashOfPath:path];
    return [[self snapshotsDirectory] stringByAppendingPathComponent:h];
}

- (NSString *)snapshotFileAtPath:(NSString *)path newText:(NSString *)newText {
    NSFileManager *fm = NSFileManager.defaultManager;
    // 目标文件尚不存在（新建）→ 没有「旧版本」可备份
    if (![fm fileExistsAtPath:path]) return nil;

    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!old) return nil;
    // 内容没变就不备份，避免点一次保存塞一条
    if (newText && [old isEqualToString:newText]) return nil;

    NSString *dir = [self snapshotDirForFile:path];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *stamp = [SPUtil timestampSlug];
    NSString *out = [dir stringByAppendingPathComponent:[stamp stringByAppendingString:@".bak"]];
    // 同名（同一秒内多次保存）加序号，绝不覆盖已有快照
    NSInteger n = 1;
    while ([fm fileExistsAtPath:out]) {
        out = [dir stringByAppendingPathComponent:
               [NSString stringWithFormat:@"%@-%ld.bak", stamp, (long)n++]];
    }
    if (![old writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return nil;

    // 同时写一份元信息，记录原文件路径（哈希不可逆，列表要用）
    NSString *meta = [dir stringByAppendingPathComponent:@"origin.txt"];
    if (![fm fileExistsAtPath:meta]) {
        [path writeToFile:meta atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    // 保留最近 20 份，避免无限增长
    [self pruneSnapshotsForFile:path keep:20];
    return out;
}

- (NSArray<NSDictionary *> *)snapshotsForFile:(NSString *)path {
    NSString *dir = [self snapshotDirForFile:path];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        if (![n hasSuffix:@".bak"]) continue;
        NSString *full = [dir stringByAppendingPathComponent:n];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        [out addObject:@{@"path": full,
                         @"name": n,
                         @"date": attr[NSFileModificationDate] ?: [NSDate date],
                         @"size": attr[NSFileSize] ?: @0}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];   // 新 → 旧
    }];
    return out;
}

- (NSString *)readSnapshotAtPath:(NSString *)snapshotPath {
    return [NSString stringWithContentsOfFile:snapshotPath encoding:NSUTF8StringEncoding error:NULL];
}

- (void)pruneSnapshotsForFile:(NSString *)path keep:(NSInteger)keep {
    if (keep <= 0) keep = 20;
    NSArray *list = [self snapshotsForFile:path];
    if ((NSInteger)list.count <= keep) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSInteger i = keep; i < (NSInteger)list.count; i++) {
        [fm removeItemAtPath:list[i][@"path"] error:NULL];
    }
}

#pragma mark JSON 读写小工具

- (id)readJSON:(NSString *)name {
    NSData *d = [NSData dataWithContentsOfFile:[self.base stringByAppendingPathComponent:name]];
    if (!d) return nil;
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
}

- (void)writeJSON:(id)obj name:(NSString *)name {
    // dataWithJSONObject 遇到非法类型（NSDate / NSNull 以外的不支持对象）
    // 会**直接抛 NSInvalidArgumentException**，不是返回 nil。
    // 这个异常如果发生在主队列回调里（构建结束时写历史），
    // 会一路走到 std::terminate → abort，表现为「编译完成后闪退」。
    // 所以这里先校验，再写。
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        SPLog(@"[!] %@ 不是合法 JSON（含非字符串/数字/数组/字典的值），跳过写入", name);
        return;
    }
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&err];
    if (!d) {
        SPLog(@"[!] 序列化 %@ 失败：%@", name, err.localizedDescription);
        return;
    }
    [d writeToFile:[self.base stringByAppendingPathComponent:name] atomically:YES];
}

- (NSString *)hashOfPath:(NSString *)path {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *d = [path dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

#pragma mark 最近项目

- (NSArray<NSDictionary *> *)recentProjects {
    id j = [self readJSON:@"recent.json"];
    return [j isKindOfClass:NSArray.class] ? j : @[];
}

- (void)pushRecentProject:(SPProject *)project {
    if (!project.path.length) return;
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *d in [self recentProjects]) {
        if ([d[@"path"] isEqual:project.path]) continue;
        [list addObject:d];
    }
    // 字典字面量遇 nil 直接抛异常，path 必须兜底
    [list insertObject:@{
        @"path": project.path ?: @"",
        @"name": project.name ?: (project.path.lastPathComponent ?: @""),
        @"kind": project.kindString ?: @"",
        @"opened": @([[NSDate date] timeIntervalSince1970]),
        @"summary": [project.options displaySummary] ?: @"",
    } atIndex:0];
    if (list.count > 30) [list removeObjectsInRange:NSMakeRange(30, list.count - 30)];
    [self writeJSON:list name:@"recent.json"];
}

- (void)removeRecentProjectAtPath:(NSString *)path {
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *d in [self recentProjects]) if (![d[@"path"] isEqual:path]) [list addObject:d];
    [self writeJSON:list name:@"recent.json"];
}

#pragma mark 构建历史

- (NSArray<NSDictionary *> *)buildHistory {
    id j = [self readJSON:@"history.json"];
    return [j isKindOfClass:NSArray.class] ? j : @[];
}

- (void)appendBuildRecord:(SPJob *)job {
    NSMutableArray *list = [NSMutableArray arrayWithObject:[job dictionaryRepresentation]];
    [list addObjectsFromArray:[self buildHistory]];
    if (list.count > 100) [list removeObjectsInRange:NSMakeRange(100, list.count - 100)];
    [self writeJSON:list name:@"history.json"];
}

#pragma mark 选项

- (SPBuildOptions *)optionsForProjectPath:(NSString *)path {
    NSString *name = [NSString stringWithFormat:@"options/%@.json", [self hashOfPath:path]];
    id j = [self readJSON:name];
    if ([j isKindOfClass:NSDictionary.class]) return [SPBuildOptions optionsFromDictionary:j];
    SPBuildOptions *o = [SPBuildOptions new];
    NSString *sdk = SPSettings.shared.defaultSDK;
    if (sdk.length == 0) o.format = SPPackageFormatRootlessDeb;
    return o;
}

- (void)saveOptions:(SPBuildOptions *)options forProjectPath:(NSString *)path {
    NSString *name = [NSString stringWithFormat:@"options/%@.json", [self hashOfPath:path]];
    [self writeJSON:[options dictionaryRepresentation] name:name];
}

#pragma mark 日志落盘

- (NSString *)persistLogText:(NSString *)text jobId:(NSString *)jobId {
    NSString *name = [NSString stringWithFormat:@"%@-%@.log", [SPUtil timestampSlug], jobId];
    NSString *path = [[self logsDirectory] stringByAppendingPathComponent:name];
    BOOL ok = [[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    return ok ? path : nil;
}

@end

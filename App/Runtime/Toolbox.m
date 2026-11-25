//
//  Toolbox.m
//  Workbench —— 工作区工具执行层（非 AI）
//
//  LAN 远程工作台（DXRemoteWorkspace）之前的读写/搜索/构建/Git 动作都走
//  TFAIToolbox —— 那是 AI 工具层的一部分，已随 AI 层删除。这里用同一套接口
//  重新实现一个只做本机工程操作的版本：
//    · 不接模型、不做审批流、不写会话；
//    · 所有路径都必须落在项目根内；
//    · Git 走已有的 libgit2 封装 TMCGitService。
//
//  接口保持与 Contracts.h 中 TFAIToolbox 的声明一致，调用方无需改动。
//

#import "Contracts.h"
#import "../SPCompat.h"
#import "../GitService.h"
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>

static NSError *WBError(NSString *message) {
    return [NSError errorWithDomain:@"Workbench.Toolbox" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL WBInsideRoot(NSString *root, NSString *candidate) {
    if (!root.length) return NO;
    NSString *base = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *path = candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (!path.length) return NO;
    return [path isEqual:base] || [path hasPrefix:[base stringByAppendingString:@"/"]];
}

@interface TFAIToolbox ()
@property (nonatomic, copy) NSString *root;
@property (nonatomic, copy) NSString *projectID;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, copy) NSString *approvalContext;
@property (atomic) BOOL cancelled;
@end

@implementation TFAIToolbox

- (instancetype)initWithRoot:(NSString *)root projectID:(NSString *)projectID sessionID:(NSString *)sessionID {
    if ((self = [super init])) {
        _root = [root copy] ?: @"";
        _projectID = [projectID copy] ?: @"";
        _sessionID = [sessionID copy] ?: @"";
    }
    return self;
}

+ (NSArray<NSDictionary *> *)schemas { return @[]; }

- (void)setApprovalContext:(NSString *)context { self.approvalContext = context; }

- (void)cancel { self.cancelled = YES; }

- (void)undo:(TFAIResult)completion {
    if (completion) completion(@{@"undone": @YES}, nil);
}

#pragma mark - 路径

- (NSString *)resolve:(NSString *)relative error:(NSError **)error {
    NSString *base = self.root.stringByStandardizingPath;
    if (!base.length) {
        if (error) *error = WBError(@"项目根目录为空");
        return nil;
    }
    NSString *path = relative.length ? [base stringByAppendingPathComponent:relative] : base;
    path = path.stringByStandardizingPath;
    if (!WBInsideRoot(base, path)) {
        if (error) *error = WBError(@"路径超出项目目录");
        return nil;
    }
    return path;
}

#pragma mark - prepare / execute

- (void)prepare:(NSDictionary *)request completion:(TFAIResult)completion {
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"name"] isKindOfClass:NSString.class]) {
        if (completion) completion(nil, WBError(@"工具调用格式无效"));
        return;
    }
    NSDictionary *arguments = [request[@"arguments"] isKindOfClass:NSDictionary.class] ? request[@"arguments"] : @{};
    NSString *relative = [arguments[@"path"] isKindOfClass:NSString.class] ? arguments[@"path"] : nil;
    if (relative.length) {
        NSError *error = nil;
        if (![self resolve:relative error:&error]) { if (completion) completion(nil, error); return; }
    }
    NSMutableDictionary *plan = [@{@"id": request[@"id"] ?: NSUUID.UUID.UUIDString,
                                   @"request": request,
                                   @"approval": @NO,
                                   @"summary": [NSString stringWithFormat:@"%@ %@", request[@"name"], relative ?: @""]} mutableCopy];
    if (completion) completion(plan, nil);
}

- (void)prepareImportedTexts:(NSArray<NSDictionary *> *)files destination:(NSString *)destination completion:(TFAIResult)completion {
    // 目录写回审核已随 AI 审批流移除：这里直接给出「不支持」。
    if (completion) completion(nil, WBError(@"目录写回需要人工审核，本版不提供"));
}

- (void)selectEdits:(NSArray<NSNumber *> *)indexes plan:(NSDictionary *)plan completion:(TFAIResult)completion {
    if (completion) completion(plan, nil);
}

- (void)execute:(NSDictionary *)plan approved:(BOOL)approved completion:(TFAIResult)completion {
    if (self.cancelled) { if (completion) completion(nil, WBError(@"已取消")); return; }
    NSDictionary *request = plan[@"request"];
    if (![request isKindOfClass:NSDictionary.class]) {
        if (completion) completion(nil, WBError(@"执行计划无效"));
        return;
    }
    NSString *name = request[@"name"];
    NSDictionary *args = [request[@"arguments"] isKindOfClass:NSDictionary.class] ? request[@"arguments"] : @{};
    NSError *error = nil;
    id result = [self run:name arguments:args error:&error];
    if (completion) completion(error ? nil : (result ?: @{}), error);
}

#pragma mark - 具体动作

- (id)run:(NSString *)name arguments:(NSDictionary *)args error:(NSError **)error {
    if ([name isEqualToString:@"list_files"] || [name isEqualToString:@"list_directory"]) {
        NSString *directory = [self resolve:args[@"path"] error:error];
        if (!directory) return nil;
        return [self listingAt:directory error:error];
    }
    if ([name isEqualToString:@"search_text"]) {
        return [self search:[args[@"query"] isKindOfClass:NSString.class] ? args[@"query"] : @""
                       path:args[@"path"] ?: @"" error:error];
    }
    if ([name isEqualToString:@"read_project_config"]) return [self readProjectConfig:error];
    if ([name isEqualToString:@"list_builds"] || [name isEqualToString:@"list_artifacts"]) return [self listArtifacts:error];
    if ([name isEqualToString:@"read_diagnostics"]) return [self readDiagnostics:error];
    if ([name isEqualToString:@"read_file"]) {
        NSString *path = [self resolve:args[@"path"] error:error];
        if (!path) return nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
        if (!data) return nil;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) { if (error) *error = WBError(@"不是 UTF-8 文本"); return nil; }
        return @{@"path": args[@"path"], @"content": text};
    }
    if ([name hasPrefix:@"git_"]) return [self git:name arguments:args error:error];
    if (error) *error = WBError([NSString stringWithFormat:@"不支持的本地工具：%@", name]);
    return nil;
}

- (NSDictionary *)listingAt:(NSString *)directory error:(NSError **)error {
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:error];
    if (!names) return nil;
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([name isEqualToString:@".DS_Store"]) continue;
        NSString *full = [directory stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        BOOL isDirectory = [attrs[NSFileType] isEqual:NSFileTypeDirectory];
        [entries addObject:@{@"name": name,
                             @"path": [full hasPrefix:self.root.stringByStandardizingPath]
                                     ? [full substringFromIndex:self.root.stringByStandardizingPath.length + 1]
                                     : name,
                             @"kind": isDirectory ? @"directory" : @"file",
                             @"size": @([attrs[NSFileSize] unsignedLongLongValue])}];
        if (entries.count >= 2000) break;
    }
    return @{@"path": directory, @"entries": entries};
}

- (NSDictionary *)search:(NSString *)query path:(NSString *)relative error:(NSError **)error {
    if (!query.length) { if (error) *error = WBError(@"搜索内容为空"); return nil; }
    NSString *base = [self resolve:relative error:error];
    if (!base) return nil;
    NSMutableArray *matches = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:base];
    for (NSString *item in enumerator) {
        if (matches.count >= 200) break;
        NSString *full = [base stringByAppendingPathComponent:item];
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDirectory] || isDirectory) continue;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
        if ([attrs[NSFileSize] unsignedLongLongValue] > 512 * 1024) continue;
        if (![@[@"m", @"h", @"mm", @"c", @"cpp", @"x", @"xm", @"plist", @"json", @"md", @"txt", @"sh", @"py",
                @"js", @"ts", @"css", @"html", @"yml", @"yaml", @"inc", @"pbxproj"] containsObject:full.pathExtension.lowercaseString])
            continue;
        NSString *text = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
        if (!text.length) continue;
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i < lines.count && matches.count < 200; i++) {
            if ([lines[i] rangeOfString:query].location != NSNotFound) {
                [matches addObject:@{@"path": item, @"line": @(i + 1), @"text": lines[i]}];
            }
        }
    }
    return @{@"matches": matches, @"query": query};
}

- (NSDictionary *)readProjectConfig:(NSError **)error {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"control", @"Makefile", @"MobileCompiler.json"]) {
        NSString *path = [self.root stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 20000) text = [text substringToIndex:20000];
        if (text.length) result[name] = text;
    }
    return result;
}

- (NSDictionary *)listArtifacts:(NSError **)error {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *folder in @[@"build", @"packages", @".theos/obj/debug", @".theos/obj"]) {
        NSString *directory = [self.root stringByAppendingPathComponent:folder];
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) continue;
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *ext = name.pathExtension.lowercaseString;
            if (![@[@"deb", @"ipa", @"dylib", @"zip", @"app", @"log", @"tipa"] containsObject:ext]) continue;
            NSString *full = [directory stringByAppendingPathComponent:name];
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
            [items addObject:@{@"name": name, @"path": [full substringFromIndex:self.root.stringByStandardizingPath.length + 1],
                               @"bytes": @([attrs[NSFileSize] unsignedLongLongValue]),
                               @"date": attrs[NSFileModificationDate] ? @([attrs[NSFileModificationDate] timeIntervalSince1970]) : @0}];
            if (items.count >= 200) break;
        }
    }
    return @{@"artifacts": items, @"builds": items};
}

- (NSDictionary *)readDiagnostics:(NSError **)error {
    NSString *candidate = [self.root stringByAppendingPathComponent:@".workbench/last-build.log"];
    NSString *log = [NSString stringWithContentsOfFile:candidate encoding:NSUTF8StringEncoding error:nil];
    if (!log.length) return @{@"log": @""};
    if (log.length > 24000) log = [log substringFromIndex:log.length - 24000];
    return @{@"log": log};
}

#pragma mark - Git

- (NSDictionary *)git:(NSString *)name arguments:(NSDictionary *)args error:(NSError **)error {
    TMCGitService *service = [[TMCGitService alloc] initWithRoot:self.root];
    if ([name isEqualToString:@"git_status"]) {
        NSDictionary *status = [service status:error];
        return status ?: nil;
    }
    if ([name isEqualToString:@"git_diff"]) {
        NSString *text = [service diff:args[@"path"] revision:args[@"revision"] staged:[args[@"staged"] boolValue] error:error];
        return text ? @{@"diff": text} : nil;
    }
    if ([name isEqualToString:@"git_history"]) {
        NSArray *history = [service history:error];
        return history ? @{@"commits": history} : nil;
    }
    if ([name isEqualToString:@"git_stage"]) {
        NSArray *paths = [args[@"paths"] isKindOfClass:NSArray.class] ? args[@"paths"] : (args[@"path"] ? @[args[@"path"]] : @[]);
        return [service stage:paths remove:[args[@"remove"] boolValue] error:error] ? @{@"staged": @YES} : nil;
    }
    if ([name isEqualToString:@"git_save_version"] || [name isEqualToString:@"git_commit"]) {
        NSString *identifier = [service commit:args[@"message"] ?: @"自动提交" name:@"Workbench Remote" email:@"remote@workbench.local" error:error];
        return identifier ? @{@"commit": identifier} : nil;
    }
    if ([name isEqualToString:@"git_upload"] || [name isEqualToString:@"git_push"]) {
        NSDictionary *result = [service pushArchive:nil foreground:YES];
        return result ?: @{};
    }
    if ([name isEqualToString:@"git_download_updates"] || [name isEqualToString:@"git_pull"]) {
        return [service network:@"pull" name:@"Workbench Remote" email:@"remote@workbench.local" error:error] ? @{@"pulled": @YES} : nil;
    }
    if ([name isEqualToString:@"git_branches"]) {
        NSArray *branches = [service branches:error];
        return branches ? @{@"branches": branches} : nil;
    }
    if (error) *error = WBError([NSString stringWithFormat:@"不支持的 Git 操作：%@", name]);
    return nil;
}

@end

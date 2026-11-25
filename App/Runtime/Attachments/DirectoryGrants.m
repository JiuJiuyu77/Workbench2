//
//  DirectoryGrants.m
//  Workbench —— 本地目录授权（无 AI）
//
//  原来的实现随 AI 附件层删除，但沙盒挂载、远程 WebDAV 和分享导入仍需要
//  「登记/撤销/校验一个目录」的能力。这里只做最小实现：
//    · 保存 security-scoped bookmark（base64），不复制、不枚举内容；
//    · 每条授权有 UUID，撤销即删除记录；
//    · 只在本机 App 容器内使用，不进入任何模型数据。
//

#import <Foundation/Foundation.h>
#import "TFAIAttachmentStore.h"

static NSString *DirectoryGrantsPath(void) {
    NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [support stringByAppendingPathComponent:@"WorkbenchDirectoryGrants"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder stringByAppendingPathComponent:@"grants.json"];
}

static NSError *GrantError(NSString *text) {
    return [NSError errorWithDomain:@"Workbench.DirectoryGrant" code:1
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

static NSArray *GrantRows(void) {
    id rows = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:DirectoryGrantsPath()] ?: NSData.data options:0 error:nil];
    return [rows isKindOfClass:NSArray.class] ? rows : @[];
}

static BOOL GrantPersist(NSArray *rows, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToFile:DirectoryGrantsPath() options:NSDataWritingAtomic error:error];
}

NSDictionary *TFAIAuthorizeDirectory(NSURL *url, NSString *source, NSError **error) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) {
        if (error) *error = GrantError(@"请选择真实目录");
        return nil;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *bookmark = nil;
    @try {
        bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:error];
    } @finally {
        if (scoped) [url stopAccessingSecurityScopedResource];
    }
    if (!bookmark) return nil;
    NSDictionary *entry = @{@"directoryGrant": NSUUID.UUID.UUIDString,
                            @"path": url.path,
                            @"name": url.lastPathComponent ?: url.path,
                            @"source": source ?: @"",
                            @"bookmark": [bookmark base64EncodedStringWithOptions:0],
                            @"addedAt": @(NSDate.date.timeIntervalSince1970)};
    NSMutableArray *rows = [GrantRows() mutableCopy];
    [rows addObject:entry];
    if (!GrantPersist(rows, error)) return nil;
    return entry;
}

BOOL TFAIRevokeDirectory(NSDictionary *entry, NSError **error) {
    NSString *identifier = entry[@"directoryGrant"];
    if (![identifier isKindOfClass:NSString.class]) {
        if (error) *error = GrantError(@"授权记录无效");
        return NO;
    }
    NSMutableArray *rows = [GrantRows() mutableCopy];
    NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) {
        return [row[@"directoryGrant"] isEqual:identifier];
    }];
    if (index == NSNotFound) return YES;
    [rows removeObjectAtIndex:index];
    return GrantPersist(rows, error);
}

NSDictionary *TFAIReadDirectoryReference(NSDictionary *entry, NSDictionary *arguments, NSError **error) {
    NSString *identifier = entry[@"directoryGrant"];
    if (![identifier isKindOfClass:NSString.class]) {
        if (error) *error = GrantError(@"授权记录无效");
        return nil;
    }
    for (NSDictionary *row in GrantRows()) {
        if (![row[@"directoryGrant"] isEqual:identifier]) continue;
        if (![NSFileManager.defaultManager fileExistsAtPath:row[@"path"] ?: @""]) {
            if (error) *error = GrantError(@"目录已移动或不存在，请重新授权");
            return nil;
        }
        return row;
    }
    if (error) *error = GrantError(@"该目录没有登记授权");
    return nil;
}

NSURL *TFAIDirectoryBrowserURL(NSDictionary *entry, NSError **error) {
    NSDictionary *row = TFAIReadDirectoryReference(entry, @{}, error);
    if (!row) return nil;
    NSString *encoded = row[@"bookmark"];
    if ([encoded isKindOfClass:NSString.class]) {
        NSData *bookmark = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (bookmark) {
            BOOL stale = NO;
            NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                            bookmarkDataIsStale:&stale error:error];
            if (url) return url;
        }
    }
    NSString *path = row[@"path"];
    return path.length ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
}

NSDictionary *TFAIDirectoryGuestSnapshot(NSDictionary *entry, NSString *relative, BOOL payload, NSError **error) {
    // 只读 guest 快照随 AI 附件层移除；沙盒挂载走 TFAIISHRuntime，不经过这里。
    if (error) *error = GrantError(@"本版不提供目录内容快照");
    return nil;
}

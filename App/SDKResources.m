#import "SDKResources.h"
#import "ArchiveImport.h"
#import <CommonCrypto/CommonDigest.h>

// 进程内编译已移除；SDK 统一来自内置 Work1 工具链：
//   Workbench.app/Toolchain/sdks/iPhoneOS<版本>.sdk
// 16.4 作为历史版本号映射到内置的 16.5。

static NSError *SDKError(NSString *message) {
    return [NSError errorWithDomain:@"WorkbenchSDK" code:4 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *TMCSDKDirectory(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Toolchain/sdks"];
}

static NSArray<NSString *> *TMCInstalledSDKVersions(void) {
    NSMutableArray *versions = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:TMCSDKDirectory() error:nil] ?: @[]) {
        if (![name hasPrefix:@"iPhoneOS"] || ![name hasSuffix:@".sdk"]) continue;
        NSString *version = [name substringWithRange:NSMakeRange(8, name.length - 8 - 4)];
        if (version.length) [versions addObject:version];
    }
    return [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b options:NSNumericSearch];
    }];
}

static NSString *TMCNormalizedVersion(NSString *version, NSError **error) {
    if (![version isKindOfClass:NSString.class] || !version.length) {
        version = TMCInstalledSDKVersions().lastObject;
    }
    if ([version isEqualToString:@"16.4"]) version = @"16.5";   // 历史默认值
    if ([TMCInstalledSDKVersions() containsObject:version]) return version;
    if (error) *error = SDKError([NSString stringWithFormat:@"找不到 SDK iPhoneOS%@；内置工具链只带 %@",
                                  version ?: @"?", [TMCInstalledSDKVersions() componentsJoinedByString:@"/"] ?: @"无"]);
    return nil;
}

NSDictionary *TMCSDKBuildSettings(NSDictionary *config, NSUserDefaults *defaults, NSError **error) {
    id sdk = config[@"sdkVersion"] ?: [defaults objectForKey:@"StudioSDKVersion"] ?: @"16.5";
    id minimum = config[@"deploymentTarget"] ?: [defaults objectForKey:@"StudioDeploymentTarget"] ?: @"15.0";
    NSString *normalized = TMCNormalizedVersion((NSString *)sdk, error);
    if (!normalized) return nil;
    NSRegularExpression *versionPattern = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,2}\\.[0-9]{1,2}(?:\\.[0-9]{1,2})?$" options:0 error:nil];
    if (![minimum isKindOfClass:NSString.class] ||
        ![versionPattern firstMatchInString:minimum options:0 range:NSMakeRange(0, [minimum length])]) {
        if (error) *error = SDKError(@"最低系统版本格式如 15.0、16.5 或 26.5");
        return nil;
    }
    if ([minimum compare:@"15.0" options:NSNumericSearch] == NSOrderedAscending ||
        [minimum compare:normalized options:NSNumericSearch] == NSOrderedDescending) {
        if (error) *error = SDKError([NSString stringWithFormat:@"最低系统版本应在 15.0 到 %@ 之间；这是当前内置工具链支持范围。", normalized]);
        return nil;
    }
    return @{@"sdkVersion": normalized, @"deploymentTarget": minimum};
}

NSString *TMCPrepareSDK(NSBundle *bundle, NSString *cacheRoot, NSError **error) {
    return TMCPrepareSelectedSDK(bundle, cacheRoot, @"16.5", error);
}

NSString *TMCPrepareSelectedSDK(NSBundle *bundle, NSString *cacheRoot, NSString *version, NSError **error) {
    NSString *normalized = TMCNormalizedVersion(version, error);
    if (!normalized) return nil;
    NSString *path = [TMCSDKDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"iPhoneOS%@.sdk", normalized]];
    if (![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"usr/include/stdio.h"]]) {
        if (error) *error = SDKError(@"内置 SDK 不完整（缺少 usr/include），请重新安装 ipa。");
        return nil;
    }
    return path;
}

BOOL TMCSDKIsInstalled(NSBundle *bundle, NSString *cacheRoot, NSString *version) {
    return TMCPrepareSelectedSDK(bundle, cacheRoot, version, NULL) != nil;
}

//
//  SPDiagnostics.m
//

#import "SPDiagnostics.h"
#import "SPModels.h"
#import "SPCompat.h"

@implementation SPRiskItem
@end

#pragma mark - Mach-O 解析（纯读字节，不依赖外部工具）

static uint32_t SPReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

@implementation SPDiagnostics

+ (NSDictionary *)binaryIndexForPath:(NSString *)binaryPath {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfFile:binaryPath
                                          options:NSDataReadingMappedIfSafe error:NULL];
    if (!data || data.length < 32) {
        out[@"error"] = @"读不到或文件太小";
        return out;
    }
    const uint8_t *b = data.bytes;
    uint32_t magic = *(const uint32_t *)b;

    if (magic != 0xfeedfacf) {   // MH_MAGIC_64
        out[@"error"] = @"不是 64 位 Mach-O（可能是 fat 二进制或非 Mach-O）";
        out[@"magic"] = [NSString stringWithFormat:@"0x%08x", magic];
        return out;
    }

    uint32_t cputype = *(const uint32_t *)(b + 4);
    uint32_t filetype = *(const uint32_t *)(b + 12);
    uint32_t ncmds = *(const uint32_t *)(b + 16);

    out[@"cpu"] = (cputype == 0x0100000c) ? @"arm64" : ((cputype == 0x0100000C) ? @"arm64e" : [NSString stringWithFormat:@"0x%x", cputype]);
    NSString *ft = @"other";
    if (filetype == 6) ft = @"dylib";
    else if (filetype == 8) ft = @"bundle";
    else if (filetype == 2) ft = @"executable";
    out[@"filetype"] = [NSString stringWithFormat:@"%@(%u)", ft, filetype];

    NSMutableArray *deps = [NSMutableArray array];
    __block BOOL hasSignature = NO;
    NSUInteger offset = 32;
    for (uint32_t i = 0; i < ncmds && offset + 8 <= data.length; i++) {
        uint32_t cmd = *(const uint32_t *)(b + offset);
        uint32_t size = *(const uint32_t *)(b + offset + 4);
        if (size < 8 || offset + size > data.length) break;

        if (cmd == 0xC || cmd == 0x8000001F) {   // LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB
            uint32_t nameOffset = *(const uint32_t *)(b + offset + 8);
            if (nameOffset < size) {
                const char *name = (const char *)(b + offset + nameOffset);
                NSString *s = [NSString stringWithUTF8String:name];
                if (s.length) [deps addObject:s];
            }
        } else if (cmd == 0x1D) {               // LC_CODE_SIGNATURE
            hasSignature = YES;
        }
        offset += size;
    }
    out[@"dependencies"] = deps;
    out[@"signed"] = @(hasSignature);
    out[@"size"] = @(data.length);
    return out;
}

#pragma mark - 构建溯源

+ (NSDictionary *)buildProvenanceForProject:(NSString *)projectPath {
    SPProject *p = [SPProject projectAtPath:projectPath error:NULL];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!p) return d;

    d[@"path"] = projectPath;
    d[@"name"] = p.name ?: @"";
    d[@"kind"] = [p kindString];
    d[@"sources"] = p.sourceFiles ?: @[];
    d[@"packageId"] = p.packageId ?: @"";
    d[@"version"] = p.version ?: @"";
    d[@"options"] = [p.options displaySummary] ?: @"";
    NSArray<NSString *> *archNames = @[@"arm64", @"arm64e", @"arm64+arm64e"];
    d[@"archs"] = archNames[(NSUInteger)p.options.arch % archNames.count];

    // 构建时间：取 .theos 目录的修改时间
    NSString *theos = [projectPath stringByAppendingPathComponent:@".theos"];
    NSDate *mtime = [NSFileManager.defaultManager attributesOfItemAtPath:theos error:NULL][NSFileModificationDate];
    if (mtime) d[@"lastBuildAt"] = [mtime description];
    return d;
}

#pragma mark - 风险

+ (NSArray<SPRiskItem *> *)runtimeRisksForProject:(NSString *)projectPath {
    NSMutableArray<SPRiskItem *> *risks = [NSMutableArray array];
    SPProject *p = [SPProject projectAtPath:projectPath error:NULL];
    if (!p) return risks;

    NSFileManager *fm = NSFileManager.defaultManager;

    // 1. tweak 有没有写过滤器（不写会注入所有进程 → 容易崩）
    if (p.kind == SPProjectKindTweak) {
        BOOL hasFilter = NO;
        for (NSString *rel in [fm subpathsAtPath:projectPath] ?: @[]) {
            if (![rel.lastPathComponent hasSuffix:@".plist"]) continue;
            NSString *full = [projectPath stringByAppendingPathComponent:rel];
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:full];
            if (d[@"Filter"]) { hasFilter = YES; break; }
        }
        BOOL writesInTree = NO;
        for (NSString *s in p.sourceFiles) {
            if ([s containsString:@"Tweak"] && ([s hasSuffix:@".x"] || [s hasSuffix:@".xm"])) { writesInTree = YES; break; }
        }
        if (!hasFilter) {
            SPRiskItem *r = [SPRiskItem new];
            r.level = writesInTree ? SPRiskLevelWarn : SPRiskLevelInfo;
            r.title = @"没有进程过滤文件";
            r.detail = @"没写 Filter（Bundles/Executables/Classes）时，tweak 会被注入所有进程，"
                        "包括系统守护进程，容易引发莫名崩溃与耗电。";
            r.suggestion = @"加一个 xxx.plist：{ Filter = { Bundles = (\"com.apple.springboard\"); }; }";
            [risks addObject:r];
        }
    }

    // 2. 架构与包布局是否匹配设备
    NSString *scheme = @"";
    if (p.options.format == SPPackageFormatRootlessDeb) scheme = @"rootless";
    else if (p.options.format == SPPackageFormatRootHideDeb) scheme = @"roothide";
    if (scheme.length) {
        SPRiskItem *r = [SPRiskItem new];
        r.level = SPRiskLevelInfo;
        r.title = [NSString stringWithFormat:@"包布局：%@", scheme];
        r.detail = @"rootless / roothide 的路径前缀与 rootful 不同，装错布局会「装了但没生效」。";
        r.suggestion = @"对照设备越狱类型选择：Dopamine 用 rootless，roothide 用 roothide。";
        [risks addObject:r];
    }

    // 3. 源码里疑似私有 API
    NSArray *privatePrefixes = @[@"_UI", @"CA", @"SpringBoard", @"LSApplicationWorkspace", @"MobileGestalt"];
    for (NSString *src in p.sourceFiles) {
        NSString *full = [projectPath stringByAppendingPathComponent:src];
        NSString *text = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:NULL];
        if (!text.length) continue;
        for (NSString *prefix in privatePrefixes) {
            if ([text rangeOfString:prefix].location != NSNotFound) {
                SPRiskItem *r = [SPRiskItem new];
                r.level = SPRiskLevelWarn;
                r.title = [NSString stringWithFormat:@"%@ 里用了 %@*", src, prefix];
                r.detail = @"私有 API 在不同系统版本上可能被移除或改签名，升级 iOS 后要重新验证。";
                [risks addObject:r];
                break;
            }
        }
    }

    // 4. 最低系统版本
    NSString *mk = [NSString stringWithContentsOfFile:p.makefilePath encoding:NSUTF8StringEncoding error:NULL];
    if (mk.length) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"TARGET\\s*=\\s*iphone:clang:[^:]+:(\\d+(?:\\.\\d+)?)" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:mk options:0 range:NSMakeRange(0, mk.length)];
        if (m.numberOfRanges > 1) {
            NSString *minVer = [mk substringWithRange:[m rangeAtIndex:1]];
            SPRiskItem *r = [SPRiskItem new];
            r.level = SPRiskLevelInfo;
            r.title = [NSString stringWithFormat:@"最低系统 iOS %@", minVer];
            r.detail = @"低于这个版本的系统不会加载本插件。";
            [risks addObject:r];
        }
    }

    // 5. 没有产物
    NSString *packages = [projectPath stringByAppendingPathComponent:@"packages"];
    if (![fm fileExistsAtPath:packages]) {
        SPRiskItem *r = [SPRiskItem new];
        r.level = SPRiskLevelInfo;
        r.title = @"还没有构建产物";
        r.detail = @"先编译一次，才能检查产物是否可安装。";
        [risks addObject:r];
    }

    return risks;
}

#pragma mark - strip 建议

+ (BOOL)shouldStripForProject:(NSString *)projectPath {
    SPProject *p = [SPProject projectAtPath:projectPath error:NULL];
    if (!p) return NO;
    return !p.options.debug;   // release 且用户没要求保留符号
}

#pragma mark - 报告

+ (NSDictionary *)reportForProject:(NSString *)projectPath binary:(NSString *)binaryPath {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"generatedAt"] = [[NSDate date] description];
    r[@"provenance"] = [self buildProvenanceForProject:projectPath] ?: @{};

    if (binaryPath.length) {
        r[@"binary"] = [self binaryIndexForPath:binaryPath] ?: @{};
    }

    NSMutableArray *risks = [NSMutableArray array];
    for (SPRiskItem *item in [self runtimeRisksForProject:projectPath]) {
        [risks addObject:@{
            @"level": @(item.level),
            @"title": item.title ?: @"",
            @"detail": item.detail ?: @"",
            @"suggestion": item.suggestion ?: @"",
        }];
    }
    r[@"risks"] = risks;
    r[@"shouldStrip"] = @([self shouldStripForProject:projectPath]);
    return r;
}

@end

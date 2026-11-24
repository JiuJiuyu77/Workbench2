//
//  SPModels.m
//

#import "SPModels.h"
#import "SPCompat.h"

#pragma mark - SPBuildOptions

static NSString *SPOptimizationFlag(SPOptimization o) {
    switch (o) {
        case SPOptimizationO0: return @"-O0";
        case SPOptimizationOg: return @"-Og";
        case SPOptimizationO1: return @"-O1";
        case SPOptimizationO3: return @"-O3";
        case SPOptimizationOs: return @"-Os";
        case SPOptimizationOz: return @"-Oz";
        case SPOptimizationOfast: return @"-Ofast";
        default: return @"-O2";
    }
}

static NSString *SPOptimizationName(SPOptimization o) {
    switch (o) {
        case SPOptimizationO0: return @"O0";
        case SPOptimizationOg: return @"Og";
        case SPOptimizationO1: return @"O1";
        case SPOptimizationO3: return @"O3";
        case SPOptimizationOs: return @"Os";
        case SPOptimizationOz: return @"Oz";
        case SPOptimizationOfast: return @"Ofast";
        default: return @"O2";
    }
}

@implementation SPBuildOptions

- (instancetype)init {
    if ((self = [super init])) {
        _arch = SPArchArm64;
        _format = SPPackageFormatRootlessDeb;
        _debug = YES;
        _optimization = SPOptimizationO2;
        _cleanBeforeBuild = NO;
        _finalize = YES;
        _signWithLdid = YES;
        _strip = NO;
        _useOLLVM = NO;
        _obfuscation = SPObfuscationLight;
        _obfuscationPasses = @[@"indbr", @"cse"];
        _parallel = YES;
        _jobs = (NSInteger)NSProcessInfo.processInfo.activeProcessorCount;
        if (_jobs < 1) _jobs = 1;
        if (_jobs > 8) _jobs = 8;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SPBuildOptions *c = [[SPBuildOptions allocWithZone:zone] init];
    c.arch = _arch; c.format = _format; c.debug = _debug;
    c.cleanBeforeBuild = _cleanBeforeBuild; c.finalize = _finalize;
    c.signWithLdid = _signWithLdid; c.strip = _strip;
    c.useOLLVM = _useOLLVM; c.obfuscation = _obfuscation;
    c.obfuscationPasses = [_obfuscationPasses copy];
    c.packageVersionOverride = [_packageVersionOverride copy];
    c.extraMakeArgs = [_extraMakeArgs copy];
    c.extraEnv = [_extraEnv copy];
    c.parallel = _parallel; c.jobs = _jobs;
    return c;
}

- (void)setObfuscation:(SPObfuscation)obfuscation {
    _obfuscation = obfuscation;
    switch (obfuscation) {
        case SPObfuscationNone:     _useOLLVM = NO; _obfuscationPasses = @[]; break;
        case SPObfuscationLight:    _useOLLVM = YES; _obfuscationPasses = @[@"indbr", @"cse"]; break;
        case SPObfuscationBalanced: _useOLLVM = YES; _obfuscationPasses = @[@"indbr", @"icall", @"cse"]; break;
        case SPObfuscationStrong:   _useOLLVM = YES; _obfuscationPasses = @[@"indbr", @"icall", @"indgv", @"cse", @"fla", @"cie", @"cfe"]; break;
        case SPObfuscationCustom:   _useOLLVM = YES; break;
    }
}

/// pass → clang flags（与 Rein tools/ollvm/manifest.json 完全一致）
static NSArray<NSString *> *SPFlagsForPass(NSString *pass) {
    NSDictionary *map = @{
        @"indbr": @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-indbr"],
        @"icall": @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-icall"],
        @"indgv": @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-indgv"],
        @"cse":   @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-cse"],
        @"fla":   @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-fla"],
        @"cie":   @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-cie"],
        @"cfe":   @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-cfe"],
        @"cff":   @[@"-mllvm", @"-irobf", @"-mllvm", @"--irobf-cff"],   // 旧版 Arkari 16
    };
    return map[pass] ?: @[];
}

- (NSString *)optimizationName { return SPOptimizationName(self.optimization); }

- (NSDictionary<NSString *, NSString *> *)makeEnvironment {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];

    // ---- 架构 ----
    switch (self.arch) {
        case SPArchArm64:
            env[@"ARCHS"] = @"arm64";
            env[@"TARGET"] = @"iphone:clang:latest:15.0";
            break;
        case SPArchArm64e:
            env[@"ARCHS"] = @"arm64e";
            env[@"TARGET"] = @"iphone:clang:latest:15.0";
            break;
        case SPArchBoth:
            env[@"ARCHS"] = @"arm64 arm64e";
            env[@"TARGET"] = @"iphone:clang:latest:15.0";
            break;
    }

    // ---- 包格式 ----
    switch (self.format) {
        case SPPackageFormatDeb:         env[@"THEOS_PACKAGE_SCHEME"] = @""; break;
        case SPPackageFormatRootlessDeb: env[@"THEOS_PACKAGE_SCHEME"] = @"rootless"; break;
        case SPPackageFormatRootHideDeb: env[@"THEOS_PACKAGE_SCHEME"] = @"roothide"; break;
        default: break; // app/tipa 不涉及 scheme
    }

    // ---- 调试 / 优化等级 ----
    NSString *opt = SPOptimizationFlag(self.optimization);
    NSString *extra = (self.optimization == SPOptimizationOz) ? @"" : @" -g";
    if (self.debug) {
        env[@"DEBUG"] = @"1";
        env[@"THEOS_DEBUG"] = @"1";
    } else {
        env[@"DEBUG"] = @"0";
    }
    env[@"OPTFLAG"] = self.strip ? opt : [opt stringByAppendingString:extra];
    env[@"RB_OPT_LEVEL"] = [self optimizationName];
    if (self.strip) env[@"STRIP"] = @"1";

    // ---- 额外环境 ----
    for (NSString *line in [self.extraEnv componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (!line.length) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [line substringToIndex:eq.location];
        NSString *v = [line substringFromIndex:eq.location + 1];
        k = [k stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (k.length) env[k] = v;
    }

    // ---- OLLVM ----
    if (self.useOLLVM && self.obfuscationPasses.count) {
        NSMutableArray *flags = [NSMutableArray array];
        for (NSString *p in self.obfuscationPasses) [flags addObjectsFromArray:SPFlagsForPass(p)];
        // Theos 的 CFLAGS/TWEAK_CFLAGS 会用在这些编译单元上
        // 新版 Theos 用 ADDITIONAL_CCFLAGS，老名字会打 deprecate 警告
        env[@"ADDITIONAL_OBJCFLAGS"] = [flags componentsJoinedByString:@" "];
        env[@"ADDITIONAL_CCFLAGS"] = [flags componentsJoinedByString:@" "];
        env[@"SP_OLLVM_PASSES"] = [self.obfuscationPasses componentsJoinedByString:@","];
    }

    if (self.packageVersionOverride.length) env[@"PACKAGE_VERSION"] = self.packageVersionOverride;

    return env;
}

- (NSArray<NSString *> *)makeArguments {
    NSMutableArray *args = [NSMutableArray array];
    if (self.cleanBeforeBuild) [args addObject:@"clean"];
    // Theos：make package → deb；make → 只编译
    if (self.finalize && self.format != SPPackageFormatApp) [args addObject:@"package"];
    else [args addObject:@"all"];
    if (self.parallel) [args addObject:[NSString stringWithFormat:@"-j%ld", (long)MAX(1, self.jobs)]];
    // 关键：不调 fakeroot 打包时容易失败，Rein 里用 FINALPACKAGE=1 走 inline 模式
    if (self.finalize && self.format != SPPackageFormatApp) {
        [args addObject:@"FINALPACKAGE=1"];
        if (self.debug) [args addObject:@"DEBUG=0"]; // FINALPACKAGE 下不能再带 -g，否则 deb 里带符号
    }
    if (self.extraMakeArgs.length) {
        for (NSString *tok in [self.extraMakeArgs componentsSeparatedByString:@" "]) {
            if (tok.length) [args addObject:tok];
        }
    }
    return args;
}

- (NSString *)displaySummary {
    NSArray *archs = @[@"arm64", @"arm64e", @"arm64+arm64e"];
    NSArray *formats = @[@"deb", @"rootless deb", @"roothide deb", @".app", @".tipa"];
    NSArray *obf = @[@"无混淆", @"轻度", @"均衡", @"强力", @"自定义"];
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:archs[self.arch]];
    [parts addObject:formats[self.format]];
    [parts addObject:self.debug ? @"debug" : @"release"];
    [parts addObject:[self optimizationName]];
    if (self.useOLLVM) [parts addObject:[NSString stringWithFormat:@"OLLVM·%@", obf[self.obfuscation]]];
    if (self.cleanBeforeBuild) [parts addObject:@"clean"];
    return [parts componentsJoinedByString:@" · "];
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"arch": @(self.arch), @"format": @(self.format), @"debug": @(self.debug), @"opt": @(self.optimization),
        @"clean": @(self.cleanBeforeBuild), @"finalize": @(self.finalize),
        @"ldid": @(self.signWithLdid), @"strip": @(self.strip),
        @"ollvm": @(self.useOLLVM), @"obf": @(self.obfuscation),
        @"passes": self.obfuscationPasses ?: @[],
        @"ver": self.packageVersionOverride ?: @"",
        @"extraArgs": self.extraMakeArgs ?: @"",
        @"extraEnv": self.extraEnv ?: @"",
        @"parallel": @(self.parallel), @"jobs": @(self.jobs),
    };
}

+ (instancetype)optionsFromDictionary:(NSDictionary *)d {
    SPBuildOptions *o = [SPBuildOptions new];
    if (![d isKindOfClass:NSDictionary.class]) return o;
    o.arch = [d[@"arch"] integerValue];
    o.format = [d[@"format"] integerValue];
    o.debug = [d[@"debug"] boolValue];
    if (d[@"opt"]) o.optimization = [d[@"opt"] integerValue];
    o.cleanBeforeBuild = [d[@"clean"] boolValue];
    o.finalize = [d[@"finalize"] boolValue];
    o.signWithLdid = [d[@"ldid"] boolValue];
    o.strip = [d[@"strip"] boolValue];
    o.useOLLVM = [d[@"ollvm"] boolValue];
    o.obfuscation = [d[@"obf"] integerValue];
    if ([d[@"passes"] isKindOfClass:NSArray.class]) o.obfuscationPasses = d[@"passes"];
    NSString *v = d[@"ver"]; if ([v isKindOfClass:NSString.class] && v.length) o.packageVersionOverride = v;
    NSString *ea = d[@"extraArgs"]; if ([ea isKindOfClass:NSString.class] && ea.length) o.extraMakeArgs = ea;
    NSString *ee = d[@"extraEnv"]; if ([ee isKindOfClass:NSString.class] && ee.length) o.extraEnv = ee;
    o.parallel = [d[@"parallel"] boolValue];
    NSInteger j = [d[@"jobs"] integerValue]; if (j > 0) o.jobs = j;
    return o;
}

@end

#pragma mark - SPProject

@interface SPProject ()
@end

@implementation SPProject

- (instancetype)init {
    if ((self = [super init])) {
        _options = [SPBuildOptions new];
        _sourceFiles = @[];
        _headers = @[];
        _lastOpenedAt = [NSDate date];
    }
    return self;
}

/// 在 dir 的直接子目录里找工程根（有 Makefile 或 package.json）。
/// 只探一层，避免在大型源码树里做全量遍历。
+ (nullable NSString *)findNestedProjectRoot:(NSString *)dir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    // 优先看名字不像隐藏目录的
    NSMutableArray *cands = [NSMutableArray array];
    for (NSString *n in items) {
        if ([n hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:n] isDirectory:&isDir] || !isDir) continue;
        [cands addObject:n];
    }
    for (NSString *n in cands) {
        NSString *sub = [dir stringByAppendingPathComponent:n];
        if ([fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"Makefile"]] ||
            [fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"makefile"]] ||
            [fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"package.json"]]) {
            return sub;
        }
    }
    // 子目录里也没有 —— 再看一层（有些包是 <name>/<版本>/Makefile）
    for (NSString *n in cands) {
        NSString *sub = [dir stringByAppendingPathComponent:n];
        NSString *deep = [self findNestedProjectRoot:sub];
        if (deep.length) return deep;
    }
    return nil;
}

+ (instancetype)projectAtPath:(NSString *)path error:(NSError **)error {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        if (error) *error = SPError(SPErrorCodeIO, [NSString stringWithFormat:@"目录不存在：%@", path]);
        return nil;
    }

    // 必须是可识别的工程：有 Makefile（Theos / Node）或 package.json
    // 否则用户导入一个空目录也会「成功」，然后点编译才发现没东西可编
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL hasMakefile = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Makefile"]] ||
                       [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"makefile"]];
    BOOL hasPackage  = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"package.json"]];

    // 兼容「源码包内嵌一层目录」的情况（BluedHush 这类发布包就是这样：
    // 解压出来是 <名字>/，里面才是 Makefile）。
    // 向上、向下各探一层，命中就把 path 换成真正的工程根。
    if (!hasMakefile && !hasPackage) {
        NSString *nested = [self findNestedProjectRoot:path];
        if (nested.length) {
            path = nested;
            hasMakefile = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Makefile"]] ||
                          [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"makefile"]];
            hasPackage  = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"package.json"]];
            SPLog(@"[工程] 发现嵌套工程根：%@", path);
        }
    }

    if (!hasMakefile && !hasPackage) {
        if (error) {
            *error = SPError(SPErrorCodeInvalidProject,
                [NSString stringWithFormat:
                 @"这里不是工程目录：%@\n\n"
                  "缺少 Makefile 或 package.json。\n"
                  "Theos 工程的根目录里一定有 Makefile；\n"
                  "如果是压缩包，确认解压后进到了正确的一层。", path]);
        }
        return nil;
    }

    SPProject *p = [SPProject new];
    p.path = path;
    [p reload];

    // Makefile 存在但没解析出产品名，说明 Makefile 内容不对
    if (p.name.length == 0) {
        if (error) *error = SPError(SPErrorCodeInvalidProject,
            @"Makefile 里没找到 TWEAK_NAME / APPLICATION_NAME，无法确定产物名。");
        return nil;
    }
    return p;
}

- (NSString *)kindString {
    switch (self.kind) {
        case SPProjectKindTweak: return @"Tweak";
        case SPProjectKindApplication: return @"App";
        case SPProjectKindLibrary: return @"Library";
        case SPProjectKindTool: return @"Tool";
        case SPProjectKindBundle: return @"Bundle";
        case SPProjectKindNode: return @"Node";
        case SPProjectKindScript: return @"Script";
        default: return @"未知";
    }
}

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager;
    self.name = self.path.lastPathComponent;
    // 兼容 Makefile / makefile 两种大小写（dylix 也是这么做的）
    NSString *makefile = [self.path stringByAppendingPathComponent:@"Makefile"];
    if (![fm fileExistsAtPath:makefile]) {
        NSString *lower = [self.path stringByAppendingPathComponent:@"makefile"];
        if ([fm fileExistsAtPath:lower]) makefile = lower;
    }
    self.makefilePath = [fm fileExistsAtPath:makefile] ? makefile : nil;
    self.isTheosProject = self.makefilePath != nil;

    // ---- 解析 Makefile / control ----
    if (self.makefilePath) {
        NSString *mk = [NSString stringWithContentsOfFile:self.makefilePath encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        if ([self firstValueOfMakeVar:@"TWEAK_NAME" in:mk]) {
            self.kind = SPProjectKindTweak;
            self.executable = [self firstValueOfMakeVar:@"TWEAK_NAME" in:mk];
        } else if ([self firstValueOfMakeVar:@"APPLICATION_NAME" in:mk]) {
            self.kind = SPProjectKindApplication;
            self.executable = [self firstValueOfMakeVar:@"APPLICATION_NAME" in:mk];
        } else if ([self firstValueOfMakeVar:@"LIBRARY_NAME" in:mk]) {
            self.kind = SPProjectKindLibrary;
            self.executable = [self firstValueOfMakeVar:@"LIBRARY_NAME" in:mk];
        } else if ([self firstValueOfMakeVar:@"TOOL_NAME" in:mk]) {
            self.kind = SPProjectKindTool;
            self.executable = [self firstValueOfMakeVar:@"TOOL_NAME" in:mk];
        } else if ([self firstValueOfMakeVar:@"BUNDLE_NAME" in:mk]) {
            self.kind = SPProjectKindBundle;
            self.executable = [self firstValueOfMakeVar:@"BUNDLE_NAME" in:mk];
        } else {
            self.kind = SPProjectKindUnknown;
        }
        NSString *includeArch = [self firstValueOfMakeVar:@"ARCHS" in:mk];
        if (includeArch.length) SPDebug(@"ARCHS=%@", includeArch);
    }

    NSString *control = [self.path stringByAppendingPathComponent:@"control"];
    if ([fm fileExistsAtPath:control]) {
        NSString *c = [NSString stringWithContentsOfFile:control encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        for (NSString *line in [c componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([t hasPrefix:@"Package:"]) self.packageId = [t substringFromIndex:8];
            else if ([t hasPrefix:@"Version:"]) self.version = [t substringFromIndex:8];
        }
        self.packageId = [self.packageId stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        self.version = [self.version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    if (!self.packageId) {
        NSString *plist = [self.path stringByAppendingPathComponent:@"Resources/Info.plist"];
        if (![fm fileExistsAtPath:plist]) plist = [self.path stringByAppendingPathComponent:@"layout/Library/Application Support/X/Info.plist"];
        self.packageId = [SPUtil stringFromPlistAtPath:plist key:@"CFBundleIdentifier" default:@""];
        if (!self.packageId.length) self.packageId = nil;
    }

    // ---- 扫源码 ----
    NSMutableArray *src = [NSMutableArray array], *hdrs = [NSMutableArray array];
    NSArray *sourceExts = @[@".x", @".xm", @".m", @".mm", @".c", @".cc", @".cpp", @".swift"];
    NSArray *headerExts = @[@".h", @".hpp"];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:self.path];
    NSString *rel;
    while ((rel = [e nextObject])) {
        if (rel.length == 0) continue;
        NSString *low = rel.lowercaseString;
        if ([low hasPrefix:@".theos"] || [low hasPrefix:@"_"] || [low hasPrefix:@"packages"] ||
            [low hasPrefix:@".git"] || [low hasPrefix:@"node_modules"]) { [e skipDescendants]; continue; }
        NSString *ext = low.pathExtension;
        NSString *dotExt = ext.length ? [@"." stringByAppendingString:ext] : @"";
        if ([sourceExts containsObject:dotExt]) [src addObject:rel];
        else if ([headerExts containsObject:dotExt]) [hdrs addObject:rel];
    }
    self.sourceFiles = [src sortedArrayUsingSelector:@selector(compare:)];
    self.headers = [hdrs sortedArrayUsingSelector:@selector(compare:)];

    // ---- 非 Theos 项目识别 ----
    if (!self.isTheosProject) {
        if ([fm fileExistsAtPath:[self.path stringByAppendingPathComponent:@"package.json"]]) {
            self.kind = SPProjectKindNode;
            NSString *pj = [self.path stringByAppendingPathComponent:@"package.json"];
            NSData *d = [NSData dataWithContentsOfFile:pj];
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if ([j isKindOfClass:NSDictionary.class]) {
                self.name = j[@"name"] ?: self.name;
                self.version = j[@"version"];
            }
        } else if ([fm fileExistsAtPath:[self.path stringByAppendingPathComponent:@"build.sh"]]) {
            self.kind = SPProjectKindScript;
        }
    }
    self.buildDir = @".theos";
}

- (nullable NSString *)firstValueOfMakeVar:(NSString *)var in:(NSString *)makefile {
    // 第 1043 轮修正（对齐 dylix 的 TheosMakefile 解析）：
    //
    // 旧实现有两个致命问题，导致「自己新建的工程」也解析失败：
    //   ① 要求 `TWEAK_NAME=` 紧贴行首 —— 但 Theos 惯例是 `TWEAK_NAME = xxx`
    //      （等号两边有空格），我们自己的模板就是这么生成的。
    //   ② 不支持 ?= / := / += 这几种赋值写法。
    //
    // 现在的做法：拆出「变量名」「赋值符」「值」三段，只比较变量名，
    // 容忍任意空格，并剥掉行尾注释。
    for (NSString *rawLine in [makefile componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (!line.length || [line hasPrefix:@"#"]) continue;

        // 变量名：字母/数字/下划线，必须从行首开始
        NSUInteger i = 0;
        NSCharacterSet *nameSet = [NSCharacterSet characterSetWithCharactersInString:
                                   @"abcdefghijklmnopqrstuvwxyz"
                                    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
        while (i < line.length && [nameSet characterIsMember:[line characterAtIndex:i]]) i++;
        if (i == 0) continue;

        NSString *name = [line substringToIndex:i];
        if (![name isEqualToString:var]) continue;

        // 跳过空白
        while (i < line.length && [[NSCharacterSet whitespaceCharacterSet]
                                   characterIsMember:[line characterAtIndex:i]]) i++;

        // 赋值符：= / ?= / := / +=
        BOOL assign = NO;
        if (i < line.length) {
            unichar c = [line characterAtIndex:i];
            if (c == '=') { assign = YES; i++; }
            else if ((c == '?' || c == ':' || c == '+') && i + 1 < line.length &&
                     [line characterAtIndex:i + 1] == '=') { assign = YES; i += 2; }
        }
        if (!assign) continue;

        NSString *v = [[line substringFromIndex:i]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // 剥掉行尾注释（不在引号内的 #）
        BOOL inQuote = NO; unichar q = 0;
        for (NSUInteger k = 0; k < v.length; k++) {
            unichar ch = [v characterAtIndex:k];
            if (inQuote) {
                if (ch == q) inQuote = NO;
            } else if (ch == '"' || ch == '\'') {
                inQuote = YES; q = ch;
            } else if (ch == '#') {
                v = [v substringToIndex:k];
                break;
            }
        }
        v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // 形如 $(XXX) 的引用不算（说明值来自别处，解析不出来）
        if ([v hasPrefix:@"$"]) continue;
        // 去掉包裹的引号
        if (v.length >= 2 &&
            (( [v hasPrefix:@"\""] && [v hasSuffix:@"\""] ) ||
             ( [v hasPrefix:@"'"]  && [v hasSuffix:@"'"]  ))) {
            v = [v substringWithRange:NSMakeRange(1, v.length - 2)];
        }
        return v.length ? v : nil;
    }
    return nil;
}

- (NSArray<NSString *> *)fileTreeFlattened {
    NSMutableArray *out = [NSMutableArray arrayWithArray:self.sourceFiles];
    [out addObjectsFromArray:self.headers];
    return out;
}

@end

#pragma mark - SPLogLine

@implementation SPLogLine
+ (instancetype)lineWithText:(NSString *)text level:(SPLogLevel)level {
    SPLogLine *l = [SPLogLine new];
    l.time = [NSDate date]; l.text = text ?: @""; l.level = level;
    return l;
}
@end

#pragma mark - SPJob

@implementation SPJob

- (instancetype)init {
    if ((self = [super init])) {
        _jobId = [[NSUUID UUID] UUIDString];
        _startedAt = [NSDate date];
        _lines = @[];
        _artifacts = @[];
        _state = SPJobStateQueued;
        _options = [SPBuildOptions new];
    }
    return self;
}

- (NSTimeInterval)duration {
    NSDate *end = self.finishedAt ?: [NSDate date];
    return [end timeIntervalSinceDate:self.startedAt];
}

- (NSString *)stateString {
    switch (self.state) {
        case SPJobStateQueued: return @"排队中";
        case SPJobStateRunning: return @"编译中";
        case SPJobStateSucceeded: return @"成功";
        case SPJobStateFailed: return @"失败";
        case SPJobStateCancelled: return @"已取消";
    }
    return @"?";
}

- (NSDictionary *)dictionaryRepresentation {
    // 字典字面量遇到 nil 会**立刻抛 NSInvalidArgumentException**
    // （attempt to insert nil object）。这里的值来自运行中的对象，
    // 任何一个为 nil 都会让「写构建历史」这一步崩溃 —— 而这个调用
    // 发生在主队列回调里，表现就是「编译完就闪退」。
    // 所以逐个兜底，不依赖字段一定有值。
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.jobId ?: @"";
    d[@"project"] = self.projectPath ?: @"";
    d[@"name"] = self.projectName ?: @"";
    d[@"state"] = @(self.state);
    d[@"target"] = @(self.target);
    d[@"exit"] = @(self.exitCode);
    d[@"started"] = @(self.startedAt ? [self.startedAt timeIntervalSince1970] : 0);
    d[@"duration"] = @(self.duration);
    d[@"finished"] = @(self.finishedAt ? [self.finishedAt timeIntervalSince1970] : 0);
    d[@"artifacts"] = self.artifacts ?: @[];
    d[@"bundle"] = self.bundlePath ?: @"";
    d[@"hint"] = self.failureHint ?: @"";
    d[@"summary"] = [self.options displaySummary] ?: @"";
    return d;
}

@end

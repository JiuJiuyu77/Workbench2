//
//  SPToolchain.m
//

#import "SPToolchain.h"
#import "SPCompat.h"
#import "SPToolchainInstaller.h"

static NSString *const kDefaultsHomeRoot = @"Workbench.homeRoot";
static NSString *const kDefaultsReinRoot = @"Workbench.reinRoot";

#pragma mark - SPToolchainProfile

@implementation SPToolchainProfile

- (instancetype)init {
    if ((self = [super init])) { _sdkName = @"iPhoneOS16.5.sdk"; _sshPort = 22; _name = @"本机"; }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)extraEnvironment {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    if (self.theosPath.length) env[@"THEOS"] = self.theosPath;
    if (self.sdkPath.length) {
        env[@"THEOS_SDK"] = self.sdkPath;
        env[@"SYSROOT"] = self.sdkPath;
    }
    if (self.ollvmRoot.length) {
        // 与 Rein 的 harness 注入命名保持一致
        env[@"CA_TOOL_OLLVM_ROOT"] = self.ollvmRoot;
        env[@"CA_TOOL_OLLVM_CLANG"] = [self.ollvmRoot stringByAppendingPathComponent:@"bin/clang"];
        env[@"CA_TOOL_OLLVM_RESOURCE_DIR"] = [self.ollvmRoot stringByAppendingPathComponent:@"lib/clang/16"];
    }
    if (self.darwinBinDir.length) {
        env[@"THEOS_TOOLCHAIN"] = self.darwinBinDir;
    }
    env[@"SP_PROFILE"] = self.name ?: @"";
    env[@"SP_TARGET"] = self.target == SPBuildTargetDevice ? @"device"
                       : (self.target == SPBuildTargetRemote ? @"remote" : @"ci");
    if (self.sshHost.length) env[@"SP_SSH_HOST"] = self.sshHost;
    return env;
}

@end

#pragma mark - SPToolchainScan

@interface SPToolchainScan ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *found;
@end

@implementation SPToolchainScan

- (instancetype)init {
    if ((self = [super init])) { _found = [NSMutableDictionary dictionary]; }
    return self;
}

- (void)setPath:(nullable NSString *)path for:(SPToolchainComponent)c {
    self.found[@(c)] = path ?: @"";
}

- (BOOL)has:(SPToolchainComponent)c {
    return [self pathFor:c].length > 0;
}

- (NSString *)pathFor:(SPToolchainComponent)c {
    return self.found[@(c)] ?: @"";
}

static NSString *const kNames[] = {@"Theos", @"SDK", @"Darwin 工具", @"OLLVM", @"逆向工具", @"Python", @"Node", @"SSH", @"Swift"};
static NSString *const kMarks[] = {@"✓", @"✗"};

- (NSString *)summary {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSInteger i = 0; i < SPToolchainComponentCount; i++) {
        NSString *name = i < (NSInteger)(sizeof(kNames) / sizeof(kNames[0])) ? kNames[i] : @"?";
        [parts addObject:[NSString stringWithFormat:@"%@ %@", name, kMarks[[self has:(SPToolchainComponent)i] ? 0 : 1]]];
    }
    return [parts componentsJoinedByString:@"  "];
}

- (NSArray<NSString *> *)remedies {
    NSMutableArray *r = [NSMutableArray array];
    if (![self has:SPToolchainComponentTheos])
        [r addObject:@"未找到 Theos：内置运行时可能没展开，去「工具链 → 展开工具链」。"];
    if (![self has:SPToolchainComponentSDK])
        [r addObject:@"未找到 iPhoneOS*.sdk：可在「工具链 → SDK 商店」里下载，或安装到 theos/sdks。"];
    if (![self has:SPToolchainComponentDarwin] && [self has:SPToolchainComponentTheos])
        [r addObject:@"编译需要 Darwin 版 clang/ld64/ldid：内置运行时里自带，检查工具链是否展开完整。"];
    if (![self has:SPToolchainComponentOLLVM])
        [r addObject:@"OLLVM 未安装：不开混淆不影响普通构建，需要时安装 Arkari LLVM 16。"];
    if (![self has:SPToolchainComponentReverse])
        [r addObject:@"逆向工具（radare2/mt-macho）未安装：签名分析、注入 dylib 会不可用。"];

    // Swift：不是「坏了」，而是设备上根本没有 swiftc
    if (![self has:SPToolchainComponentSwift]) {
        [r addObject:@"Swift 不可用：设备上找不到 swiftc 编译器。\n"
                 "  · 含 .swift 的工程无法编译（.m / .x 工程不受影响）\n"
                 "  · 内置运行时不含 Swift 工具链（官方 iOS 分发本身也不带）\n"
                 "  · 需要 Swift 时，可用「GitHub CI」在云端用 Xcode 构建"];
    }

    // SSH 单独说明：iOS 系统本身不带 ssh 客户端，
    // 只打一个叉会让人以为功能坏了。
    if (![self has:SPToolchainComponentDevices]) {
        [r addObject:@"SSH 不可用：iOS 不自带 ssh 客户端，也没有内置在运行时里。\n"
                 "  · 不影响本机编译\n"
                 "  · 需要远程构建时，用「局域网工作台」或「GitHub CI」，两者都不依赖 ssh"];
    }
    return r;
}

@end

#pragma mark - SPToolchain

@interface SPToolchain ()
@property (nonatomic, strong) SPToolchainScan *scan;
@property (nonatomic, copy, nullable) NSString *resolvedDarwin;
@property (nonatomic, copy, nullable) NSString *resolvedOLLVM;
@property (nonatomic, copy, nullable) NSString *resolvedReverse;
@property (nonatomic, copy, nullable) NSString *resolvedPython;
@property (nonatomic, copy, nullable) NSString *resolvedNode;
@property (nonatomic, copy, nullable) NSString *resolvedSSH;
@property (nonatomic, copy, nullable) NSString *resolvedSwift;
@end

@implementation SPToolchain

/// 自动找 Rein / DSH.app 的运行时根目录。
///
/// 判定依据：目录下同时有 theos-root 与 sdks（Rein 的特征），
/// 或者有 tools/theos-root（Rein 源码目录的特征）。
+ (nullable NSString *)discoverReinRoot {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // ① 用户目录
    [candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Rein"]];

    // ② 已安装的 App（TrollStore / 越狱都在这两个位置之一）
    for (NSString *base in @[@"/var/containers/Bundle/Application",
                             @"/private/var/containers/Bundle/Application",
                             @"/Applications"]) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:base error:NULL] ?: @[]) {
            NSString *dir = [base stringByAppendingPathComponent:uuid];
            // 先看 UUID 这一层是不是 App 本体
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"theos-root"] isDirectory:&isDir] && isDir) {
                [candidates addObject:dir];
            }
            // 再看里面的 *.app（DSH.app / Rein.app）
            for (NSString *sub in [fm contentsOfDirectoryAtPath:dir error:NULL] ?: @[]) {
                if (![sub.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                [candidates addObject:[dir stringByAppendingPathComponent:sub]];
            }
        }
    }

    for (NSString *c in candidates) {
        BOOL d1 = NO, d2 = NO;
        [fm fileExistsAtPath:[c stringByAppendingPathComponent:@"theos-root"] isDirectory:&d1];
        [fm fileExistsAtPath:[c stringByAppendingPathComponent:@"sdks"] isDirectory:&d2];
        if (d1 && d2) {
            SPLog(@"自动发现 Rein 运行时：%@", c);
            return c;
        }
        // 源码目录形态
        NSString *tr = [c stringByAppendingPathComponent:@"tools/theos-root"];
        if ([fm fileExistsAtPath:tr isDirectory:&d1] && d1) {
            SPLog(@"自动发现 Rein 源码目录：%@", c);
            return c;
        }
    }
    return nil;
}

+ (instancetype)shared {
    static SPToolchain *t; static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [SPToolchain new];
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        // Rein 有两个常见安装位置：
        //   ① /var/mobile/Documents/Rein        —— 用户自己解压的目录
        //   ② /var/containers/Bundle/Application/<UUID>/DSH.app
        //      —— TrollStore 安装的 App 本体（实际最常见）
        // 之前只认 ①，所以装了 Rein App 也探测不到工具链。
        // Workbench 运行时已完整内嵌，不再自动探测外部 Rein/DSH 目录
        // （之前会指向别人的安装，让人误以为检测错了）
        // 清掉历史版本自动探测时存下的外部 Rein 路径 ——
        // 用户从没手动指定过，留着它会让工具链继续指向 Rein。
        // 只有用户主动设置过（kDefaultsHomeRoot）才沿用。
        NSString *savedRein = [d stringForKey:kDefaultsReinRoot];
        if (savedRein.length && [savedRein containsString:@"Documents/Rein"]) {
            [d removeObjectForKey:kDefaultsReinRoot];
            savedRein = nil;
            SPLog(@"已清除历史遗留在的 Rein 路径配置");
        }
        t.reinRoot = savedRein ?: @"";
        t.homeRoot = [d stringForKey:kDefaultsHomeRoot];
        [t rescan];
    });
    return t;
}

- (void)setReinRoot:(NSString *)reinRoot {
    _reinRoot = [reinRoot copy];
    [NSUserDefaults.standardUserDefaults setObject:reinRoot forKey:kDefaultsReinRoot];
}

- (void)setHomeRoot:(NSString *)homeRoot {
    _homeRoot = [homeRoot copy];
    if (homeRoot.length) [NSUserDefaults.standardUserDefaults setObject:homeRoot forKey:kDefaultsHomeRoot];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kDefaultsHomeRoot];
}

#pragma mark 候选根目录

- (NSArray<NSString *> *)candidateRoots {
    NSMutableArray *roots = [NSMutableArray array];

    // 1) 内置工具链（ipa 里带的，首启展开到 Documents/Workbench/Toolchain）
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    if (inst.isInstalled) {
        // 安装目录的布局是 <root>/bin、<root>/theos、<root>/ollvm、<root>/reverse
        // 为了让下面的相对路径探测直接命中，这里把它的上级目录塞进来
        [roots addObject:[inst.installRoot stringByDeletingLastPathComponent]];
        [roots addObject:inst.installRoot];
    }

    // 2) **App 包内自带的运行时优先**
    //    Workbench 已完整内嵌（288 工具 + 3 SDK），不该再依赖任何外部目录。
    //    之前外部 Rein 目录排在前，导致工具链指向别人的安装，
    //    用户看到「检测到的目录并非 Workbench」。
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    [roots addObject:bundle];

    // 3) 用户手动指定的目录（可选）
    //
    // **不再把 reinRoot 放进来**：
    // Workbench 的运行时完整内嵌在 App 包里，混入别人的安装目录只会出错 ——
    // 实测生成的构建脚本会变成
    //   PATH=/var/mobile/Documents/Rein/tools/theos-root/usr/bin:...
    //   CA_TOOL_OLLVM_CLANG=/var/mobile/Documents/Rein/tools/ollvm/bin/clang
    // 等于用 Rein 的工具链编译 Workbench 的工程，路径、版本都不匹配。
    if (self.homeRoot.length) [roots addObject:self.homeRoot];
    return roots;
}

/// 依次尝试 "<root>/<rel>"，返回第一个存在且是目录的
- (nullable NSString *)firstExistingDirectory:(NSArray<NSString *> *)rels fromRoots:(NSArray<NSString *> *)roots {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        for (NSString *rel in rels) {
            NSString *p = rel.length ? [root stringByAppendingPathComponent:rel] : root;
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
        }
    }
    return nil;
}

- (nullable NSString *)firstExistingFile:(NSArray<NSString *> *)rels fromRoots:(NSArray<NSString *> *)roots {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        for (NSString *rel in rels) {
            NSString *p = [root stringByAppendingPathComponent:rel];
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    return nil;
}

#pragma mark 扫描

/// 距上次扫描超过 minInterval 秒才真正重扫。
/// 返回 YES 表示这次真的扫了。
- (BOOL)rescanIfStale:(NSTimeInterval)minInterval {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.lastScanTime > 0 && (now - self.lastScanTime) < minInterval) return NO;
    [self rescan];
    return YES;
}

- (void)rescan {
    self.lastScanTime = [NSDate date].timeIntervalSince1970;
    SPToolchainScan *scan = [SPToolchainScan new];
    NSArray *roots = [self candidateRoots];
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1) Theos：tools/theos-local、tools/theos-full、theos-root/theos、…/theos
    NSString *theos = [self firstExistingDirectory:@[@"Workbench/Toolchain/theos", @"Toolchain/theos",
                                                     @"theos",
                                                     @"tools/theos-local",
                                                     @"theos-root/theos", @"tools/theos-root/theos",
                                                     @"Theos"] fromRoots:roots];
    if (!theos) {
        // 包内 DSH.app/theos-root/theos 可能只读，但也能用
        NSString *alt = [self firstExistingDirectory:@[@"theos-root/theos"] fromRoots:@[[NSBundle mainBundle].bundlePath]];
        theos = alt;
    }
    [scan setPath:theos for:SPToolchainComponentTheos];

    // 2) SDK
    //
    // 判定条件必须是「目录里有 SDKSettings.json」，不能只看目录名 ——
    // theos-root/theos/sdks 里只有一个 .keep 占位，会把探测带偏。
    // 搜索位置（按优先级）：
    //   theos-full/sdks        ← 我们的运行时把真实 SDK 放这
    //   <THEOS>/sdks           ← Theos 标准位置
    //   顶层 sdks/             ← Rein 布局
    NSString *sdk = nil;
    NSMutableArray<NSString *> *sdkDirs = [NSMutableArray array];

    // 候选目录：把所有可能的位置都列出来
    if (theos) [sdkDirs addObject:[theos stringByAppendingPathComponent:@"sdks"]];
    for (NSString *rel in @[@"sdks",                       // 顶层（DSH/Rein 布局）
                            @"theos-root/theos/sdks",      // 平铺后 Theos 自己的 sdks
                            @"theos-full/sdks",
                            @"Workbench/SDKs", @"SDKs", @"sdks-store"]) {
        for (NSString *root in roots) {
            [sdkDirs addObject:[root stringByAppendingPathComponent:rel]];
        }
    }

    // 逐个目录找 iPhoneOS*.sdk，且必须含 SDKSettings.json。
    //
    // **优先完整 SDK**：运行时里 16.5 / 17.0 只有 SDKSettings.json 和
    // Frameworks，没有 usr/include —— 这种半成品能通过「有 SDKSettings」
    // 的旧判定，被选成默认 SDK，然后在编译时找不到 stdio.h 报一堆
    // 「file not found」。所以先找完整的，完整的一个都没有才退回半成品。
    NSString *sdkFallback = nil;
    for (NSString *dir in sdkDirs) {
        if (![fm fileExistsAtPath:dir]) continue;
        NSArray *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in names ?: @[]) {
            if (![name hasPrefix:@"iPhoneOS"] || ![name hasSuffix:@".sdk"]) continue;
            NSString *cand = [dir stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"SDKSettings.json"]]) continue;
            if (![self sdkDirectoryIsComplete:cand]) {
                if (!sdkFallback) sdkFallback = cand;
                continue;
            }
            sdk = cand;
            break;
        }
        if (sdk) break;
    }
    if (!sdk) sdk = sdkFallback;

    // 兜底：上面的固定路径都没命中时，直接在包内浅层扫描
    // （最多 3 层深，避免遍历整个 500MB SDK）
    if (!sdk) {
        NSString *bundle = [NSBundle mainBundle].bundlePath;
        NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:bundle];
        NSInteger visited = 0;
        while (queue.count && visited < 400) {
            NSString *cur = queue.firstObject;
            [queue removeObjectAtIndex:0];
            visited++;
            NSArray *items = [fm contentsOfDirectoryAtPath:cur error:NULL];
            for (NSString *it in items ?: @[]) {
                if (![it hasSuffix:@".sdk"]) continue;
                NSString *full = [cur stringByAppendingPathComponent:it];
                if ([fm fileExistsAtPath:[full stringByAppendingPathComponent:@"SDKSettings.json"]]) {
                    sdk = full;
                    break;
                }
            }
            if (sdk) break;
            // 只往下走 2 层
            if ([cur componentsSeparatedByString:@"/"].count <
                [bundle componentsSeparatedByString:@"/"].count + 3) {
                for (NSString *it in items ?: @[]) {
                    BOOL isDir = NO;
                    NSString *full = [cur stringByAppendingPathComponent:it];
                    if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                        // 跳过明显无关的大目录
                        if ([it isEqualToString:@"Frameworks"] || [it isEqualToString:@"_CodeSignature"]) continue;
                        [queue addObject:full];
                    }
                }
            }
        }
    }

    [scan setPath:sdk for:SPToolchainComponentSDK];

    // 诊断：只在结果**变化**时写日志。
    // 以前每次 rescan 都打一行「SDK 已找到」，项目页每刷新一次列表就扫一次，
    // 日志被刷成一片，真正有用的信息反而被淹没。
    static NSString *sLastSDK = nil;
    if (sdk) {
        if (![sdk isEqualToString:sLastSDK ?: @""]) {
            SPLog(@"SDK 已找到：%@", sdk);
            sLastSDK = [sdk copy];
        }
    } else {
        NSMutableString *dbg = [NSMutableString string];
        [dbg appendString:@"SDK 未找到。已探测的候选目录："];
        NSUInteger n = 0;
        for (NSString *d in sdkDirs) {
            if (n++ > 12) break;
            [dbg appendFormat:@"\n  %@ %@", [fm fileExistsAtPath:d] ? @"✓" : @"✗", d];
        }
        SPLog(@"%@", dbg);
        SPLog(@"roots（%lu 个）：%@", (unsigned long)roots.count, [roots componentsJoinedByString:@", "]);
    }

    // 3) Darwin bin：theos-root/usr/bin / helpers（真机可执行）
    //    平铺布局下是 Workbench.app/theos-root/usr/bin
    NSString *darwin = [self firstExistingDirectory:@[@"theos-root/usr/bin",
                                                       @"Workbench/Toolchain/bin", @"Toolchain/bin",
                                                       @"usr/bin", @"tools/theos-root/usr/bin"]
                                          fromRoots:roots];
    if (!darwin) darwin = [self firstExistingDirectory:@[@"helpers"] fromRoots:[@[[NSBundle mainBundle].bundlePath] arrayByAddingObjectsFromArray:roots]];
    // 至少要真有 clang/ld64 才算
    if (darwin && ![[darwin stringByAppendingPathComponent:@"ld64"] isKindOfClass:NSNull.class]
        && ![fm fileExistsAtPath:[darwin stringByAppendingPathComponent:@"ld64"]]
        && ![fm fileExistsAtPath:[darwin stringByAppendingPathComponent:@"clang-16"]]
        && ![fm fileExistsAtPath:[darwin stringByAppendingPathComponent:@"clang"]]) {
        darwin = nil;
    }
    self.resolvedDarwin = darwin;
    [scan setPath:darwin for:SPToolchainComponentDarwin];

    // 4) OLLVM
    NSString *ollvm = [self firstExistingDirectory:@[@"Workbench/Toolchain/ollvm", @"Toolchain/ollvm",
                                                     @"tools/ollvm", @"ollvm"] fromRoots:roots];
    if (ollvm && ![fm fileExistsAtPath:[ollvm stringByAppendingPathComponent:@"bin/clang"]]) ollvm = nil;
    self.resolvedOLLVM = ollvm;
    [scan setPath:ollvm for:SPToolchainComponentOLLVM];

    // 5) 逆向工具
    NSString *rev = [self firstExistingDirectory:@[@"reverse/bin",
                                                    @"Workbench/Toolchain/reverse/bin", @"Toolchain/reverse/bin",
                                                    @"tools/reverse/bin"] fromRoots:roots];
    // 判定：只要 mt-macho / rabin2 / r2 任一存在即可
    // （Rein 的 reverse/bin 里没有 rabin2，早先过严会导致整个组件被判为未安装）
    if (rev) {
        BOOL ok = [fm fileExistsAtPath:[rev stringByAppendingPathComponent:@"mt-macho"]] ||
                  [fm fileExistsAtPath:[rev stringByAppendingPathComponent:@"rabin2"]] ||
                  [fm fileExistsAtPath:[rev stringByAppendingPathComponent:@"r2"]];
        if (!ok) rev = nil;
    }
    self.resolvedReverse = rev;
    [scan setPath:rev for:SPToolchainComponentReverse];

    // 6) python / node / ssh
    // python-runtime 里的可执行名不固定（有 python3 / python / python3.13 等），
    // 也可能只有 Python.framework（真正解释器在 framework 内）。
    self.resolvedPython = [self firstExistingFile:@[@"python-runtime/python3",
                                                     @"python-runtime/python3.13",
                                                     @"python-runtime/python",
                                                     @"tools/python/python3",
                                                     @"tools/python/python",
                                                     @"bin/python3", @"usr/bin/python3"] fromRoots:roots];
    if (!self.resolvedPython) {
        // 退回：只要 python-runtime/Python.framework 在，就认为装了（解释器在 framework 里）
        NSString *prd = [self firstExistingDirectory:@[@"python-runtime/Python.framework",
                                                        @"Python.framework"] fromRoots:roots];
        if (prd) self.resolvedPython = prd;
    }
    [scan setPath:self.resolvedPython for:SPToolchainComponentPython];

    // node22 可能是「单个可执行文件」（Rein 就是这样），也可能是目录
    NSString *node = [self firstExistingFile:@[@"node22/node", @"node22/bin/node",
                                               @"bin/node22", @"bin/node",
                                               @"helpers/node"] fromRoots:roots];
    if (!node) {
        NSString *nodeFile = [self firstExistingFile:@[@"node22"] fromRoots:roots];
        if (nodeFile) node = nodeFile;   // 直接就是可执行文件
    }
    self.resolvedNode = node;
    [scan setPath:self.resolvedNode for:SPToolchainComponentNode];

    // SSH 不在搜索常见系统路径里通常是因为根本没装 ——
    // iOS 不带 ssh，需要单独装 OpenSSH（Rein 也不自带）。
    // 这里把工具链目录也纳入搜索（有些包会带 OpenSSH 客户端），
    // 找不到时状态文案要说明「未安装」而不是只打个叉。
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    NSMutableArray *sshDirs = [NSMutableArray arrayWithObjects:
        @"/usr/bin", @"/usr/local/bin", @"/bin",
        @"/var/jb/usr/bin", @"/var/jb/bin", @"/usr/sbin", @"/var/jb/usr/sbin", nil];
    for (NSString *d in @[inst.binDir, inst.baseBinDir,
                          [inst.installRoot stringByAppendingPathComponent:@"helpers"],
                          [inst.installRoot stringByAppendingPathComponent:@"usr/sbin"]]) {
        if (d.length) [sshDirs addObject:d];
    }
    self.resolvedSSH = [SPUtil findExecutable:@[@"ssh"] searchDirs:sshDirs];

    // Swift 编译器：设备上极少见（Rein / Codex / TrollAgent 都没带）。
    // 没有它，含 .swift 文件的工程无法编译 —— 检测出来是为了
    // 在界面上给出明确提示，而不是让用户看 make 的一句 "swiftc: not found"。
    self.resolvedSwift = [SPUtil findExecutable:@[@"swiftc"]
                                     searchDirs:@[inst.binDir,
                                                  [inst.installRoot stringByAppendingPathComponent:@"usr/bin"],
                                                  @"/usr/bin", @"/var/jb/usr/bin"]];
    [scan setPath:self.resolvedSwift for:SPToolchainComponentSwift];
    [scan setPath:self.resolvedSSH for:SPToolchainComponentDevices];

    self.scan = scan;
    SPDebug(@"scan: %@", [scan summary]);
}

- (NSArray<NSString *> *)sdkNamesInDirectory:(NSString *)dir {
    NSMutableArray *names = [NSMutableArray array];
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[];
    for (NSString *n in all) {
        if ([n hasSuffix:@".sdk"] && [n hasPrefix:@"iPhoneOS"]) [names addObject:n];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

/// 所有可能放 SDK 的目录，顺序即优先级。
///
/// **必须与 resolvedSDKPathNamed / rescan 共用同一套**。
/// 以前这里是另一份旧列表（Workbench/SDKs、SDKs、tools/theos-full/sdks、
/// tools/theos-local/sdks、sdks-store —— 全是 Rein 的旧布局），
/// 平铺安装后真实 SDK 在 Workbench.app/theos-root/theos/sdks，
/// 这里一个都命中不了，于是工具链页永远显示「尚未安装 SDK」，
/// 而项目页却能正常构建（那边走的是另一套路径）。
- (NSArray<NSString *> *)sdkDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *theos = [self.scan pathFor:SPToolchainComponentTheos];
    if (theos.length) [dirs addObject:[theos stringByAppendingPathComponent:@"sdks"]];
    for (NSString *root in [self candidateRoots]) {
        for (NSString *rel in @[@"theos-root/theos/sdks", @"theos/sdks", @"sdks",
                                @"theos-full/sdks", @"theos-local/sdks",
                                @"tools/theos-full/sdks", @"tools/theos-local/sdks",
                                @"sdks-store", @"Workbench/SDKs", @"SDKs"]) {
            NSString *d = [root stringByAppendingPathComponent:rel];
            if (![dirs containsObject:d]) [dirs addObject:d];
        }
    }
    return dirs;
}

/// SDK 是否完整可用：SDKSettings.json + usr/include 缺一不可。
/// 缺 usr/include 时 clang 连 stdio.h 都找不到，编译必然失败。
- (BOOL)sdkDirectoryIsComplete:(NSString *)sdkPath {
    if (!sdkPath.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[sdkPath stringByAppendingPathComponent:@"SDKSettings.json"]]) return NO;
    return [fm fileExistsAtPath:[sdkPath stringByAppendingPathComponent:@"usr/include"]];
}

- (NSArray<NSString *> *)availableSDKs {
    return [self availableSDKsIncludingIncomplete:NO];
}

- (NSArray<NSString *> *)availableSDKsIncludingIncomplete:(BOOL)includeIncomplete {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in [self sdkDirectories]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        for (NSString *n in [self sdkNamesInDirectory:dir]) {
            if ([out containsObject:n]) continue;
            NSString *cand = [dir stringByAppendingPathComponent:n];
            if (!includeIncomplete && ![self sdkDirectoryIsComplete:cand]) continue;
            [out addObject:n];
        }
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

/// 按名字找 SDK 的绝对路径（找不到返回 nil）
- (nullable NSString *)sdkPathForName:(nullable NSString *)name {
    if (!name.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in [self sdkDirectories]) {
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:cand]) return cand;
    }
    return nil;
}

- (nullable NSString *)resolvedSDKPathNamed:(nullable NSString *)sdkName {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *want = sdkName.length ? sdkName : nil;

    // 与 rescan 用**同一套候选目录**。
    //
    // 以前这里写死 tools/theos-full/sdks、tools/theos-local/sdks、sdks-store
    // —— 全是 Rein 的旧布局。平铺安装后真实 SDK 在
    // Workbench.app/theos-root/theos/sdks，这里一个都命中不了，
    // 于是出现「工具链页显示 SDK ✓、项目页却报没找到 SDK」。
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *theos = [self.scan pathFor:SPToolchainComponentTheos];
    if (theos.length) [dirs addObject:[theos stringByAppendingPathComponent:@"sdks"]];
    for (NSString *root in [self candidateRoots]) {
        for (NSString *rel in @[@"theos-root/theos/sdks", @"sdks", @"theos-full/sdks",
                                @"theos-local/sdks", @"tools/theos-full/sdks",
                                @"tools/theos-local/sdks", @"sdks-store",
                                @"Workbench/SDKs", @"SDKs"]) {
            [dirs addObject:[root stringByAppendingPathComponent:rel]];
        }
    }

    // 收集所有完整 SDK（必须有 SDKSettings.json，排除 .keep 占位目录）
    NSMutableDictionary<NSString *, NSString *> *byName = [NSMutableDictionary dictionary];
    for (NSString *dir in dirs) {
        for (NSString *n in [self sdkNamesInDirectory:dir]) {
            if (byName[n]) continue;
            NSString *cand = [dir stringByAppendingPathComponent:n];
            if (![fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"SDKSettings.json"]]) continue;
            byName[n] = cand;
        }
    }

    // ① 精确命中用户指定的名字 —— 但只在它完整时采用。
    //    半成品 SDK（缺 usr/include）一定会编译失败，
    //    宁可退回到完整的那一个，也不要「按用户要求」踩坑。
    if (want && byName[want] && [self sdkDirectoryIsComplete:byName[want]]) return byName[want];

    // ② 用户没指定（或指定的版本已不存在）→ 用 rescan 选中的那个
    NSString *scanned = [self.scan pathFor:SPToolchainComponentSDK];
    if (scanned.length && [self sdkDirectoryIsComplete:scanned]) return scanned;

    // ③ 兜底：版本号最高且完整的一个
    NSArray *sorted = [[byName allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *n in [sorted reverseObjectEnumerator]) {
        if ([self sdkDirectoryIsComplete:byName[n]]) return byName[n];
    }
    return nil;
}

#pragma mark Profile

- (SPToolchainProfile *)localProfileWithSDK:(NSString *)sdkName error:(NSError **)error {
    [self rescan];
    SPToolchainProfile *p = [SPToolchainProfile new];
    p.target = SPBuildTargetDevice;
    p.name = @"本机";
    p.theosPath = [self.scan pathFor:SPToolchainComponentTheos].length ? [self.scan pathFor:SPToolchainComponentTheos] : nil;
    p.darwinBinDir = self.resolvedDarwin;
    p.ollvmRoot = self.resolvedOLLVM;
    p.reverseBinDir = self.resolvedReverse;
    p.python3 = self.resolvedPython;
    p.node = self.resolvedNode;
    p.sdkPath = [self resolvedSDKPathNamed:sdkName];
    p.sdkName = p.sdkPath.lastPathComponent ?: (sdkName ?: @"");
    if (!p.theosPath) {
        if (error) *error = SPError(SPErrorCodeMissingToolchain,
            @"没找到 Theos。请把 Theos 安装到 Rein/tools/theos-local，或在设置里指定安装目录。");
        return nil;
    }
    if (!p.sdkPath) {
        if (error) *error = SPError(SPErrorCodeMissingToolchain,
            @"没找到 iPhoneOS SDK。可从 Rein 的 sdks-store 复制，或在工具链页下载。");
        return nil;
    }
    return p;
}

- (SPToolchainProfile *)remoteProfileWithHost:(NSString *)host
                                         user:(NSString *)user
                                         port:(NSInteger)port
                                          sdk:(NSString *)sdkName {
    SPToolchainProfile *p = [SPToolchainProfile new];
    p.target = SPBuildTargetRemote;
    p.name = [NSString stringWithFormat:@"远程 %@@%@", user.length ? user : @"mobile", host];
    p.sshHost = host; p.sshUser = user.length ? user : @"mobile"; p.sshPort = port ?: 22;
    p.sdkName = sdkName ?: @"";
    // 远程的路径由远端决定，这里只留空让远端自己探测
    return p;
}

- (SPToolchainProfile *)ciProfileWithSDK:(NSString *)sdkName {
    SPToolchainProfile *p = [SPToolchainProfile new];
    p.target = SPBuildTargetCI;
    p.name = @"GitHub CI";
    p.sdkName = sdkName ?: @"iPhoneOS16.5.sdk";
    return p;
}

- (NSString *)pathPrefixForProfile:(SPToolchainProfile *)profile {
    NSMutableArray *dirs = [NSMutableArray array];
    if (profile.darwinBinDir.length) [dirs addObject:profile.darwinBinDir];
    if (profile.theosPath.length) [dirs addObject:[profile.theosPath stringByAppendingPathComponent:@"bin"]];
    // 真机上的系统目录优先于 xbin
    [dirs addObjectsFromArray:@[@"/var/jb/usr/bin", @"/usr/bin", @"/usr/local/bin", @"/bin", @"/usr/sbin", @"/sbin"]];
    return [dirs componentsJoinedByString:@":"];
}


NSString *SPToolchainInstallerBinDir(void) {
    SPToolchainInstaller *i = [SPToolchainInstaller shared];
    return i.isInstalled ? i.binDir : @"";
}

@end

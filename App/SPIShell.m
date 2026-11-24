//
//  SPIShell.m
//  Workbench —— iSH（Alpine Linux）工具补充
//
//  默认关闭：iSH 的每条命令都要跨进程进 Alpine，构建时明显拖慢速度。
//  只有用户在「设置 → 显示与反馈 → iSH Linux 工具补充」里手动开启才启用。
//
//  为什么保留：Theos 的部分构建脚本按 Linux 写（sed -i 无后缀、grep -P、
//  tar --strip-components），Darwin 侧会报错；需要时用它补这几个命令。
//  编译、链接、签名始终走 Darwin 工具链，不经 iSH。
//

#import "SPIShell.h"
#import "SPCompat.h"
#import "SPSession.h"

static NSString *const kIShellEnabledKey = @"Workbench.ishellEnabled";

@interface SPIShell ()
@property (nonatomic, assign) SPIShellState state;
@property (nonatomic, copy, nullable) NSString *executablePath;
@end

@implementation SPIShell

+ (instancetype)shared {
    static SPIShell *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SPIShell new];
        s->_state = SPIShellStateUnknown;
    });
    return s;
}

/// 总开关：默认关闭（用户明确要求 iSH 不作为默认路径）
+ (BOOL)isEnabledByUser {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kIShellEnabledKey] == nil) return NO;   // 默认关
    return [d boolForKey:kIShellEnabledKey];
}

#pragma mark - 探测

/// iSH 可执行入口候选（装了 iSH 的常见位置）
- (NSArray<NSString *> *)candidatePaths {
    NSMutableArray *c = [NSMutableArray array];
    // iSH 的 CLI 入口：iSH.app 内的 ish 或 run.sh
    for (NSString *app in @[@"/private/var/containers/Bundle/Application",
                            @"/Applications",
                            @"/var/jb/Applications"]) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray *subs = [fm contentsOfDirectoryAtPath:app error:NULL] ?: @[];
        for (NSString *sub in subs) {
            NSString *dir = [app stringByAppendingPathComponent:sub];
            NSString *bundle = [dir stringByAppendingPathComponent:@"iSH.app"];
            [c addObject:[bundle stringByAppendingPathComponent:@"ish"]];
            [c addObject:[bundle stringByAppendingPathComponent:@"run.sh"]];
        }
    }
    // 越狱 / rootless 下的常见落点
    [c addObject:@"/var/jb/usr/bin/ish"];
    [c addObject:@"/usr/bin/ish"];
    return c;
}

- (void)probeForce:(BOOL)force completion:(void (^)(SPIShellState, NSString *))completion {
    if (!force && self.state != SPIShellStateUnknown) {
        if (completion) completion(self.state, self.executablePath ?: @"");
        return;
    }

    // 开关关闭 → 直接判定不可用，不做任何探测（零开销）
    if (![SPIShell isEnabledByUser]) {
        self.state = SPIShellStateUnusable;
        self.executablePath = nil;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(SPIShellStateUnusable, @"iSH 补充已在设置中关闭（推荐保持关闭）");
            });
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *found = nil;
        for (NSString *p in [self candidatePaths]) {
            if ([fm isExecutableFileAtPath:p]) { found = p; break; }
        }
        SPIShellState st = found ? SPIShellStateAvailable : SPIShellStateNotInstalled;
        NSString *detail = found ? found : @"未找到 iSH.app（请先安装 iSH）";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.state = st;
            self.executablePath = found;
            if (completion) completion(st, detail);
        });
    });
}

#pragma mark - 执行

- (nullable NSString *)runCommandSync:(NSString *)command
                              timeout:(NSTimeInterval)timeout
                                error:(NSError **)error {
    if (![SPIShell isEnabledByUser]) {
        if (error) *error = [NSError errorWithDomain:@"SPIShell" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"iSH 补充未开启"}];
        return nil;
    }
    if (!self.executablePath.length) {
        if (error) *error = [NSError errorWithDomain:@"SPIShell" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"iSH 未安装或不可用"}];
        return nil;
    }

    // 经 iSH 的 run.sh 执行：-c 后接命令
    NSString *script = [NSString stringWithFormat:@"'%@' -c %@",
                        self.executablePath,
                        [SPUtil shellQuote:command]];
    SPCommandResult *r = [SPSession runSyncShell:script
        environment:@{@"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin"}
                                          cwd:NSHomeDirectory()
                                      timeout:timeout > 0 ? timeout : 30];
    if (r.exitCode != 0 && error) {
        *error = [NSError errorWithDomain:@"SPIShell" code:r.exitCode
            userInfo:@{NSLocalizedDescriptionKey:
                r.stderrText.length ? r.stderrText : @"iSH 命令执行失败"}];
    }
    return r.stdoutText;
}

- (void)runCommand:(NSString *)command
            timeout:(NSTimeInterval)timeout
         completion:(void (^)(BOOL, NSString *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *err = nil;
        NSString *out = [self runCommandSync:command timeout:timeout error:&err];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(out != nil, out, err);
            });
        }
    });
}

#pragma mark - 能力展示

- (NSArray<NSString *> *)availableTools {
    if (![SPIShell isEnabledByUser] || self.state != SPIShellStateAvailable) return @[];
    // 只做一次轻量探测，不逐个跑（会很慢）
    NSError *err = nil;
    NSString *out = [self runCommandSync:@"ls /usr/bin | head -40" timeout:20 error:&err];
    if (!out.length) return @[];
    NSMutableArray *tools = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        if (line.length) [tools addObject:line];
    }
    return tools;
}

/// 构建脚本环境前缀：**仅当用户开启且 iSH 可用**才追加，
/// 否则返回空串（构建脚本保持原样，不受影响）。
- (NSString *)pathFallbackSnippet {
    if (![SPIShell isEnabledByUser]) return @"";
    if (self.state != SPIShellStateAvailable) return @"";
    return @"export PATH=\"$PATH:/usr/bin:/bin\"\n";
}

@end

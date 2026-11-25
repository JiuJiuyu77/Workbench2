//
//  WorkbenchHealth.m
//

#import "WorkbenchHealth.h"
#import "SPToolchainInstaller.h"
#import "SPToolchain.h"
#import "SPBuilder.h"
#import "SPModels.h"
#import "SPProcessGuard.h"
#import "SPJIT.h"
#import "Runtime/Sandbox/TFAIISHRuntime.h"

@implementation WBHealthItem

+ (instancetype)item:(NSString *)identifier
               title:(NSString *)title
               level:(WBHealthLevel)level
              detail:(NSString *)detail
                hint:(NSString *)hint {
    WBHealthItem *i = [WBHealthItem new];
    i.identifier = identifier;
    i.title = title;
    i.level = level;
    i.detail = detail ?: @"";
    i.hint = hint;
    return i;
}

- (NSString *)levelText {
    switch (self.level) {
        case WBHealthLevelOK: return @"通过";
        case WBHealthLevelWarn: return @"警告";
        default: return @"失败";
    }
}

@end

@implementation WBHealthReport

- (BOOL)ok { return self.failCount == 0; }

- (NSUInteger)failCount {
    NSUInteger n = 0;
    for (WBHealthItem *i in self.items) if (i.level == WBHealthLevelFail) n++;
    return n;
}

- (NSUInteger)warnCount {
    NSUInteger n = 0;
    for (WBHealthItem *i in self.items) if (i.level == WBHealthLevelWarn) n++;
    return n;
}

- (NSString *)summary {
    if (self.items.count == 0) return @"未检查";
    if (self.failCount == 0 && self.warnCount == 0) {
        return [NSString stringWithFormat:@"%lu 项全部通过", (unsigned long)self.items.count];
    }
    if (self.failCount == 0) {
        return [NSString stringWithFormat:@"%lu 项通过，%lu 项警告",
                (unsigned long)(self.items.count - self.warnCount), (unsigned long)self.warnCount];
    }
    return [NSString stringWithFormat:@"%lu 项失败，%lu 项警告",
            (unsigned long)self.failCount, (unsigned long)self.warnCount];
}

- (NSString *)plainText {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Workbench 环境自检：%@\n\n", [self summary]];
    for (WBHealthItem *i in self.items) {
        [s appendFormat:@"[%@] %@\n", [i levelText], i.title];
        if (i.detail.length) [s appendFormat:@"      %@\n", i.detail];
        if (i.hint.length) [s appendFormat:@"      建议：%@\n", i.hint];
    }
    return s;
}

@end

@implementation WBHealth

+ (NSString *)resourceRoot {
    return [NSBundle mainBundle].bundlePath ?: @"";
}

static unsigned long long WBFreeBytes(void) {
    // 不依赖 statfs 的字段布局，用 URL 资源值，跨 SDK 版本稳定
    NSError *err = nil;
    NSURL *url = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSDictionary *v = [url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey]
                                           error:&err];
    NSNumber *n = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    return n ? n.unsignedLongLongValue : 0;
}

static BOOL WBPathIsDir(NSString *p) {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir;
}

static BOOL WBFileExists(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

/// xcframework 是否包含指定架构切片
+ (WBHealthReport *)runChecks {
    NSMutableArray<WBHealthItem *> *items = [NSMutableArray array];
    NSString *root = [self resourceRoot];
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1. 基础：bundle 可读
    [items addObject:[WBHealthItem item:@"bundle"
                                  title:@"应用资源目录"
                                  level:root.length ? WBHealthLevelOK : WBHealthLevelFail
                                 detail:root.length ? root : @"无法定位 bundle 路径"
                                   hint:root.length ? nil : @"安装包可能损坏，请重新安装"]];

    // 2. SDK（内置 Toolchain/sdks，Theos 直接使用）
    NSString *tc = [root stringByAppendingPathComponent:@"Toolchain"];
    if (!WBPathIsDir(tc)) tc = root;
    NSString *sdks = [tc stringByAppendingPathComponent:@"sdks"];
    NSMutableArray<NSString *> *sdkVersions = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:sdks error:NULL] ?: @[]) {
        if ([name hasPrefix:@"iPhoneOS"] && [name hasSuffix:@".sdk"]) {
            [sdkVersions addObject:[name substringWithRange:NSMakeRange(8, name.length - 12)]];
        }
    }
    NSString *builtinSDK = [sdks stringByAppendingPathComponent:@"iPhoneOS16.5.sdk"];
    BOOL sdkSettings = WBFileExists([builtinSDK stringByAppendingPathComponent:@"SDKSettings.plist"]);
    BOOL sdkHeaders = WBFileExists([builtinSDK stringByAppendingPathComponent:@"usr/include/stdio.h"]);
    [items addObject:[WBHealthItem item:@"sdk.builtin" title:@"内置 iOS 16.5 SDK"
                                  level:(sdkSettings && sdkHeaders) ? WBHealthLevelOK : WBHealthLevelFail
                                 detail:(sdkSettings && sdkHeaders)
                                        ? [NSString stringWithFormat:@"可用版本：%@", [sdkVersions componentsJoinedByString:@", "] ?: @"16.5"]
                                        : [NSString stringWithFormat:@"SDKSettings=%@ · stdio.h=%@",
                                           sdkSettings ? @"有" : @"缺", sdkHeaders ? @"有" : @"缺"]
                                   hint:(sdkSettings && sdkHeaders) ? nil : @"内置工具链不完整，请重新安装 ipa"]];

    // 3. 工具链组件
    NSArray *toolchainChecks = @[
        @[@"theos.makefiles", @"theos-full/makefiles/common.mk", @"Theos makefiles"],
        @[@"clang16", @"theos-root/usr/bin/clang-16", @"编译器 clang-16"],
        @[@"ld64", @"theos-root/usr/bin/ld64", @"链接器 ld64"],
        @[@"ldid", @"theos-root/usr/bin/ldid", @"签名工具 ldid"],
        @[@"make", @"theos-root/usr/bin/make", @"GNU make"],
        @[@"perl", @"theos-root/usr/bin/perl", @"Perl（Logos 预处理）"],
        @[@"logos", @"theos-full/bin/logos.pl", @"Logos 生成器"],
        @[@"ollvm", @"ollvm/bin/clang", @"OLLVM 混淆编译器"],
        @[@"r2", @"reverse/bin/r2", @"radare2"],
        @[@"mtmacho", @"reverse/bin/mt-macho", @"mt-macho"],
        @[@"swiftc", @"swift-toolchain/usr/bin/swiftc", @"Swift 编译器"],
    ];
    for (NSArray *row in toolchainChecks) {
        NSString *path = [tc stringByAppendingPathComponent:row[1]];
        BOOL exists = WBFileExists(path);
        [items addObject:[WBHealthItem item:row[0] title:row[2]
                                      level:exists ? WBHealthLevelOK : WBHealthLevelFail
                                     detail:exists ? row[1] : [@"缺少 " stringByAppendingString:row[1]]
                                       hint:exists ? nil : @"全内置版本应自带该项，请重新安装 ipa"]];
    }

    // 4. 运行时（iSH 沙盒 / JIT / 基础命令）
    BOOL hasRootfs = WBFileExists([root stringByAppendingPathComponent:@"iSH/alpine-minirootfs-3.21.0-aarch64.tar.gz"]);
    [items addObject:[WBHealthItem item:@"runtime.rootfs" title:@"Linux 运行时（Alpine rootfs）"
                                  level:hasRootfs ? WBHealthLevelOK : WBHealthLevelFail
                                 detail:hasRootfs ? @"rootfs 归档存在" : @"缺少 iSH rootfs"
                                   hint:hasRootfs ? nil : @"终端与 Linux 工具链不可用，请重装 ipa"]];
    NSString *bash = [tc stringByAppendingPathComponent:@"helpers/bash"];
    BOOL hasBash = WBFileExists(bash);
    [items addObject:[WBHealthItem item:@"runtime.shell" title:@"子进程 Shell"
                                  level:hasBash ? WBHealthLevelOK : WBHealthLevelFail
                                 detail:hasBash ? bash : @"缺少 helpers/bash"
                                   hint:hasBash ? nil : @"构建子进程无法启动"]];
    BOOL jitd = WBFileExists([[NSBundle.mainBundle bundlePath] stringByAppendingPathComponent:@"bin/spark-jitd"]);
    [items addObject:[WBHealthItem item:@"runtime.jitd" title:@"JIT 授权 helper"
                                  level:jitd ? WBHealthLevelOK : WBHealthLevelWarn
                                 detail:jitd ? @"bin/spark-jitd 存在" : @"缺少 bin/spark-jitd"
                                   hint:jitd ? nil : @"JIT 将退回主进程探测"]];
    [items addObject:[WBHealthItem item:@"runtime.sandbox" title:@"Linux 沙盒状态"
                                  level:[TFAIISHRuntime available] ? WBHealthLevelOK : WBHealthLevelWarn
                                 detail:[TFAIISHRuntime available] ? @"可启动" : @"当前构建未启用（-DWORKBENCH_HAS_ISH=0）"
                                   hint:nil]];

    // 5. 运行环境（容器 / 权限 / JIT）
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    BOOL container = [docs containsString:@"/Containers/Data/Application/"] || [docs containsString:@"/Containers/Shared/AppGroup/"];
    [items addObject:[WBHealthItem item:@"env.container" title:@"数据容器"
                                  level:container ? WBHealthLevelOK : WBHealthLevelWarn
                                 detail:container ? docs : [NSString stringWithFormat:@"未隔离（%@）", docs ?: @"nil"]
                                   hint:container ? nil : @"平台权限下 Documents 指向共享目录，存储清理会停用"]];
    BOOL persona = [[SPProcessGuard shared] personaAPIAvailable];
    [items addObject:[WBHealthItem item:@"env.persona" title:@"root persona 能力"
                                  level:(getuid() == 0 || persona) ? WBHealthLevelOK : WBHealthLevelWarn
                                 detail:[NSString stringWithFormat:@"uid=%d · persona API=%@", (int)getuid(), persona ? @"可用" : @"不可用"]
                                   hint:(getuid() == 0 || persona) ? nil : @"需要 TrollStore 平台签名（重新安装 ipa）"]];
    [items addObject:[WBHealthItem item:@"env.jit" title:@"JIT 可执行内存"
                                  level:[SPJIT shared].isEnabled ? WBHealthLevelOK : WBHealthLevelWarn
                                 detail:[SPJIT shared].statusText
                                   hint:[SPJIT shared].isEnabled ? nil : @"到「执行环境」点「JIT 授权」，或开启开发者模式"]];

    // 6. 磁盘空间
    unsigned long long free = WBFreeBytes();
    double gb = free / 1073741824.0;
    if (free == 0) {
        [items addObject:[WBHealthItem item:@"disk" title:@"可用空间"
                                      level:WBHealthLevelWarn detail:@"无法读取可用空间" hint:nil]];
    } else if (gb < 1.0) {
        [items addObject:[WBHealthItem item:@"disk" title:@"可用空间"
                                      level:WBHealthLevelFail
                                     detail:[NSString stringWithFormat:@"仅剩 %.2f GB", gb]
                                       hint:@"构建产物与中间文件需要 1 GB 以上"]];
    } else if (gb < 3.0) {
        [items addObject:[WBHealthItem item:@"disk" title:@"可用空间"
                                      level:WBHealthLevelWarn
                                     detail:[NSString stringWithFormat:@"仅剩 %.1f GB", gb]
                                       hint:@"大型工程编译可能中途空间不足"]];
    } else {
        [items addObject:[WBHealthItem item:@"disk" title:@"可用空间"
                                      level:WBHealthLevelOK
                                     detail:[NSString stringWithFormat:@"%.1f GB 可用", gb] hint:nil]];
    }

    // 7. 工程目录可写
    BOOL writable = docs.length && [fm isWritableFileAtPath:docs];
    [items addObject:[WBHealthItem item:@"storage" title:@"工程目录可写"
                                  level:writable ? WBHealthLevelOK : WBHealthLevelFail
                                 detail:writable ? docs : @"Documents 不可写"
                                   hint:writable ? nil : @"检查设备存储权限或剩余空间"]];

    WBHealthReport *r = [WBHealthReport new];
    r.items = items;
    return r;
}

@end

#pragma mark - 自检界面

@interface WBHealthViewController : UITableViewController
@property (nonatomic, strong) WBHealthReport *report;
@end


#pragma mark - 快速构建测试

static void WBHealthAlert(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static void WBQuickBuild(UIViewController *host) {
    SPToolchainInstaller *installer = [SPToolchainInstaller shared];
    if (!installer.isInstalled) {
        WBHealthAlert(host, @"工具链未就绪", @"请先在「设置 → 工具链」完成内置工具链安装。");
        return;
    }
    NSError *error = nil;
    SPToolchainProfile *profile = [[SPToolchain shared] localProfileWithSDK:nil error:&error];
    if (!profile) {
        WBHealthAlert(host, @"工具链不可用", error.localizedDescription ?: @"无法生成构建 profile");
        return;
    }
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *root = [documents stringByAppendingPathComponent:[@"QuickTest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *makefile = @"TARGET = iphone:clang:16.5:15.0\nARCHS = arm64\ninclude $(THEOS)/makefiles/common.mk\n\nTWEAK_NAME = QuickTest\nQuickTest_FILES = Tweak.xm\n\ninclude $(THEOS)/makefiles/tweak.mk\n";
    NSString *control = @"Package: com.workbench.quicktest\nName: QuickTest\nVersion: 0.0.1\nArchitecture: iphoneos-arm\nDescription: Workbench quick build test\nMaintainer: Workbench\nAuthor: Workbench\nSection: Tweaks\n";
    NSString *tweak = @"#import <Foundation/Foundation.h>\n\n%hook NSObject\n%end\n";
    [makefile writeToFile:[root stringByAppendingPathComponent:@"Makefile"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [control writeToFile:[root stringByAppendingPathComponent:@"control"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [tweak writeToFile:[root stringByAppendingPathComponent:@"Tweak.xm"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    SPProject *project = [SPProject projectAtPath:root error:&error];
    if (!project) {
        WBHealthAlert(host, @"样例工程无效", error.localizedDescription ?: root);
        return;
    }
    UIAlertController *waiting = [UIAlertController alertControllerWithTitle:@"正在快速构建…"
                                                                    message:@"使用内置 Theos 编译样例 tweak，稍后显示结果。"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:waiting animated:YES completion:nil];
    NSMutableString *log = [NSMutableString string];
    NSDate *started = NSDate.date;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [SPBuilder buildProject:project options:project.options profile:profile
                         onLine:^(NSString *line, SPLogLevel level) {
            if (line.length) [log appendFormat:@"%@\n", line];
        } onFinish:^(SPJob *job) {
            ok = (job.exitCode == 0);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)));
        double seconds = -[started timeIntervalSinceNow];
        NSString *logPath = [root stringByAppendingPathComponent:@"quickbuild.log"];
        [log writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        NSArray *tail = lines.count > 12 ? [lines subarrayWithRange:NSMakeRange(lines.count - 12, 12)] : lines;
        NSString *message = [NSString stringWithFormat:@"%@ · %.1f 秒\n%@\n\n日志：%@",
                             ok ? @"构建成功" : @"构建失败", seconds, [tail componentsJoinedByString:@"\n"], logPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            [waiting dismissViewControllerAnimated:YES completion:^{
                WBHealthAlert(host, ok ? @"快速构建通过" : @"快速构建失败", message);
            }];
        });
    });
}

@implementation WBHealthViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"环境自检";
    self.report = [WBHealth runChecks];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(exportReport)];
}

- (void)exportReport {
    NSString *text = [self.report plainText];
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[text] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 2) return 2;
    return (NSInteger)self.report.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"总述" : (section == 1 ? @"检查项" : @"操作");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:@"cell"];
    if (indexPath.section == 2) {
        cell.textLabel.text = indexPath.row == 0 ? @"运行快速构建测试" : @"重新自检";
        cell.detailTextLabel.text = indexPath.row == 0 ? @"编译内置样例 tweak（约 10–60 秒）" : @"重新读取运行时、工具链与环境状态";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.imageView.image = [UIImage systemImageNamed:indexPath.row == 0 ? @"hammer.fill" : @"arrow.clockwise"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (indexPath.section == 0) {
        cell.textLabel.text = [self.report summary];
        cell.textLabel.textColor = self.report.ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
        cell.detailTextLabel.text = @"点击右上角可导出完整报告";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    WBHealthItem *item = self.report.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.detail;
    cell.detailTextLabel.numberOfLines = 2;
    switch (item.level) {
        case WBHealthLevelOK:
            cell.textLabel.textColor = UIColor.labelColor;
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            cell.imageView.tintColor = UIColor.systemGreenColor;
            break;
        case WBHealthLevelWarn:
            cell.textLabel.textColor = UIColor.labelColor;
            cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            cell.imageView.tintColor = UIColor.systemOrangeColor;
            break;
        default:
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.imageView.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
            cell.imageView.tintColor = UIColor.systemRedColor;
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        if (indexPath.row == 0) WBQuickBuild(self);
        else { self.report = [WBHealth runChecks]; [self.tableView reloadData]; }
        return;
    }
    if (indexPath.section == 0) return;
    WBHealthItem *item = self.report.items[(NSUInteger)indexPath.row];
    NSMutableString *msg = [NSMutableString stringWithString:item.detail ?: @""];
    if (item.hint.length) [msg appendFormat:@"\n\n建议：%@", item.hint];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:item.title
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

UIViewController *WBHealthController(void) {
    return [[WBHealthViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}

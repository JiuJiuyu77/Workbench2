//
//  WorkbenchHealth.m
//

#import "WorkbenchHealth.h"

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
+ (WBHealthItem *)xcframeworkItem:(NSString *)name
                          sliceDir:(NSString *)slice
                         required:(BOOL)required {
    NSString *root = [self resourceRoot];
    NSString *xf = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"Vendor/%@.xcframework", name]];
    if (!WBPathIsDir(xf)) {
        return [WBHealthItem item:[NSString stringWithFormat:@"xcframework.%@", name]
                            title:[NSString stringWithFormat:@"%@ 框架", name]
                            level:required ? WBHealthLevelFail : WBHealthLevelWarn
                           detail:[NSString stringWithFormat:@"缺少 %@.xcframework", name]
                             hint:@"执行 scripts/fetch_resources.sh 补齐 Vendor 依赖"];
    }
    NSString *slicePath = [xf stringByAppendingPathComponent:slice];
    if (!WBPathIsDir(slicePath)) {
        return [WBHealthItem item:[NSString stringWithFormat:@"xcframework.%@", name]
                            title:[NSString stringWithFormat:@"%@ 框架", name]
                            level:WBHealthLevelFail
                           detail:[NSString stringWithFormat:@"%@ 缺少 %@ 切片", name, slice]
                             hint:@"框架包不完整，重新获取 Vendor 依赖"];
    }
    return [WBHealthItem item:[NSString stringWithFormat:@"xcframework.%@", name]
                        title:[NSString stringWithFormat:@"%@ 框架", name]
                        level:WBHealthLevelOK
                       detail:[NSString stringWithFormat:@"%@ / %@ 存在", name, slice]
                         hint:nil];
}

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

    // 2. iOS SDK（工程内置 16.4；26.0 为可选项）
    NSString *sdk = [root stringByAppendingPathComponent:@"SDK"];
    if (WBPathIsDir(sdk)) {
        NSString *settings = [sdk stringByAppendingPathComponent:@"SDKSettings.json"];
        BOOL hasSettings = WBFileExists(settings);
        BOOL hasInclude = WBPathIsDir([sdk stringByAppendingPathComponent:@"usr/include"]);
        if (hasSettings && hasInclude) {
            [items addObject:[WBHealthItem item:@"sdk.builtin" title:@"内置 iOS SDK"
                                          level:WBHealthLevelOK
                                         detail:@"SDKSettings.json 与 usr/include 齐全"
                                           hint:nil]];
        } else {
            [items addObject:[WBHealthItem item:@"sdk.builtin" title:@"内置 iOS SDK"
                                          level:WBHealthLevelFail
                                         detail:[NSString stringWithFormat:@"SDK 不完整（SDKSettings=%@, usr/include=%@）",
                                                 hasSettings ? @"有" : @"缺", hasInclude ? @"有" : @"缺"]
                                           hint:@"SDK 目录被裁剪过，请重新获取完整 SDK"]];
        }
    } else {
        [items addObject:[WBHealthItem item:@"sdk.builtin" title:@"内置 iOS SDK"
                                      level:WBHealthLevelFail
                                     detail:@"缺少 Resources/SDK"
                                       hint:@"构建产物缺少 SDK，请检查打包步骤"]];
    }

    // 3. 可选 SDK（26.0）
    NSString *local = [root stringByAppendingPathComponent:@"../LocalSDKs"];
    NSArray *sdkDirs = [fm contentsOfDirectoryAtPath:local error:NULL];
    NSUInteger extraSDK = 0;
    for (NSString *n in sdkDirs) {
        if ([n hasSuffix:@".sdk"]) extraSDK++;
    }
    if (extraSDK > 0) {
        [items addObject:[WBHealthItem item:@"sdk.optional" title:@"可选 SDK"
                                      level:WBHealthLevelOK
                                     detail:[NSString stringWithFormat:@"检测到 %lu 个附加 SDK", (unsigned long)extraSDK]
                                       hint:nil]];
    } else {
        [items addObject:[WBHealthItem item:@"sdk.optional" title:@"可选 SDK"
                                      level:WBHealthLevelWarn
                                     detail:@"未检测到附加 SDK（不影响默认构建）"
                                       hint:@"需要更高 SDK 时可在「安装工具」中下载"]];
    }

    // 4. 内置工具链（当前唯一构建路线：Theos / make）
    NSString *tc = [root stringByAppendingPathComponent:@"Toolchain"];
    if (!WBPathIsDir(tc)) tc = root;   // 兼容平铺布局
    NSArray *checks = @[
        @[@"clang-16", @"theos-root/usr/bin/clang-16", @"编译器"],
        @[@"ld64", @"theos-root/usr/bin/ld64", @"链接器"],
        @[@"ldid", @"theos-root/usr/bin/ldid", @"签名工具"],
        @[@"make", @"theos-root/usr/bin/make", @"构建工具"],
        @[@"perl", @"theos-root/usr/bin/perl", @"Perl（Logos 预处理）"],
        @[@"ollvm", @"ollvm/bin/clang", @"OLLVM 混淆编译器"],
        @[@"r2", @"reverse/bin/r2", @"逆向工具 radare2"],
        @[@"swiftc", @"swift-toolchain/usr/bin/swiftc", @"Swift 编译器"],
    ];
    for (NSArray *row in checks) {
        NSString *path = [tc stringByAppendingPathComponent:row[1]];
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
        [items addObject:[WBHealthItem item:row[0] title:row[2]
                                      level:exists ? WBHealthLevelOK : WBHealthLevelFail
                                     detail:exists ? row[1] : [@"缺少 " stringByAppendingString:row[1]]
                                       hint:exists ? nil : @"请重新安装 ipa（全内置版本自带工具链）"]];
    }

    // 7. 磁盘空间
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

    // 8. 工程目录可写（构建输出位置）
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    BOOL writable = docs.length && [fm isWritableFileAtPath:docs];
    [items addObject:[WBHealthItem item:@"storage"
                                  title:@"工程目录可写"
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.report.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"总述" : @"检查项";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:@"cell"];
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

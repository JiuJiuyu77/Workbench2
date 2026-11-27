//
//  WBTheosToolsController.m
//  Workbench —— Theos 工具链管理（dylix 界面风格）
//

#import "WBTheosToolsController.h"
#import "SPToolchainInstaller.h"
#import "SPToolchainDownloader.h"
#import "SPCompat.h"
#import "SPSession.h"
#import "GlassSupport.h"

@interface WBTheosToolsListController : UITableViewController
@property (nonatomic, strong) NSArray<SPComponentInfo *> *items;
@property (nonatomic, assign) BOOL busy;
- (void)reload;
- (void)refreshAll;
- (void)refreshVersions;
@end


#pragma mark - 版本

// iOS 没有 NSTask，统一走 SPSession 的子进程（与构建同一套工具链环境）。
//
// **必须后台执行**：SPSession 的 runSyncShell 会同步等待子进程结束，
// 主线程调用会被直接拒绝（stderr「内部错误：同步 Shell 不能在主线程调用」），
// 表现就是「当前版本全部显示内部错误」，而且界面会卡住。
// 这里改成：后台队列探测一次 → 结果缓存 → 主线程只读缓存并刷新。
static NSArray<NSString *> *WBVersionTools(void) {
    return @[@"clang", @"ld64", @"ld64.lld", @"ldid", @"make", @"perl", @"swiftc", @"r2"];
}

static NSArray<NSString *> *WBVersionCommands(void) {
    return @[@"clang --version", @"ld64 --version", @"ld64.lld --version", @"ldid -v",
             @"make --version", @"perl -e 'printf \"%vd\\n\", $^V'",
             @"swiftc --version", @"r2 -v"];
}

static NSMutableDictionary<NSString *, NSString *> *WBVersionCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

/// 只在主线程读写（避免并发探测）。
static BOOL gWBVersionProbing = NO;

static NSString *WBVersionOutput(NSString *command) {
    SPCommandResult *result = [SPSession runSyncShell:command
                                          environment:[[SPToolchainInstaller shared] runtimeEnvironment]
                                                  cwd:NSTemporaryDirectory()
                                              timeout:20];
    NSString *text = [NSString stringWithFormat:@"%@%@", result.stdoutText ?: @"", result.stderrText ?: @""];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) return trimmed;
    }
    return @"未安装";
}

/// 后台探测所有工具的版本；completion 回到主线程。
static void WBVersionProbe(BOOL force, void (^completion)(void)) {
    if (gWBVersionProbing) return;
    if (!force && WBVersionCache().count >= WBVersionTools().count) {
        if (completion) completion();
        return;
    }
    gWBVersionProbing = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSString *> *names = WBVersionTools();
        NSArray<NSString *> *commands = WBVersionCommands();
        NSMutableDictionary<NSString *, NSString *> *found = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < names.count && i < commands.count; i++) {
            @autoreleasepool {
                found[names[i]] = WBVersionOutput(commands[i]);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [WBVersionCache() addEntriesFromDictionary:found];
            gWBVersionProbing = NO;
            if (completion) completion();
        });
    });
}

static NSArray<NSArray<NSString *> *> *WBInstalledVersions(void) {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    for (NSString *tool in WBVersionTools()) {
        NSString *value = WBVersionCache()[tool] ?: @"检测中…";
        [rows addObject:@[tool, value]];
    }
    return rows;
}

@implementation WBTheosToolsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theos 工具链";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    TMCCardTableStyle(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(refreshAll)];
    [self reload];
    [self refreshVersions];
}

- (void)reload {
    self.busy = YES;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[SPToolchainDownloader shared] reload];
        NSArray *list = [[SPToolchainDownloader shared] components];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items = list;
            self.busy = NO;
            [self.tableView reloadData];
        });
    });
}

/// 刷新按钮：重新扫组件 + 强制重探版本。
- (void)refreshAll {
    [self reload];
    [self refreshVersions];
}

/// 重新探测版本（点刷新按钮时强制刷新）。
- (void)refreshVersions {
    __weak typeof(self) weakSelf = self;
    WBVersionProbe(YES, ^{
        [weakSelf.tableView reloadData];
    });
}

#pragma mark - 数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 2) return WBInstalledVersions().count;
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"安装位置";
    if (section == 2) return @"当前版本";
    return @"可安装组件";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"工具链解包在应用沙盒内，随 App 卸载删除。构建时通过 PATH 注入，不修改系统目录。";
    }
    return @"构建只需「Theos 基础」一项；OLLVM / 逆向工具按需下载，SDK 17 与 26 仅在项目选择对应版本时需要。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"WBTheosCard";
    TMCCardCell *cell = [TMCCardCell cellInTable:tableView reuseIdentifier:cid];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 2) {
        NSArray<NSArray<NSString *> *> *versions = WBInstalledVersions();
        if (indexPath.row >= (NSInteger)versions.count) return cell;
        NSArray<NSString *> *row = versions[(NSUInteger)indexPath.row];
        BOOL missing = [row[1] isEqualToString:@"未安装"] || [row[1] isEqualToString:@"检测中…"];
        [cell configureWithTitle:row[0] detail:row[1] symbol:@"number.circle"
                            tint:(missing ? UIColor.systemOrangeColor : UIColor.systemGreenColor)];
        cell.detailTextLabel.numberOfLines = 2;
        return cell;
    }

    if (indexPath.section == 0) {
        SPToolchainInstaller *inst = [SPToolchainInstaller shared];
        [cell configureWithTitle:(inst.isInstalled ? @"已安装" : (inst.hasBundledToolchain ? @"待安装" : @"未安装"))
                          detail:(inst.isInstalled ? inst.installRoot : @"点此安装内置工具链")
                          symbol:@"wrench.and.screwdriver.fill"
                            tint:(inst.isInstalled ? UIColor.systemGreenColor : UIColor.systemOrangeColor)];
        cell.textLabel.textColor = inst.isInstalled ? UIColor.labelColor : UIColor.systemOrangeColor;
        cell.selectionStyle = inst.isInstalled ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if (indexPath.row >= (NSInteger)self.items.count) return cell;
    SPComponentInfo *info = self.items[indexPath.row];
    [cell configureWithTitle:info.title detail:info.detail symbol:info.symbol tint:UIColor.systemBlueColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 76, 28)];
    badge.textAlignment = NSTextAlignmentRight;
    badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    if (info.isInstalled) {
        badge.text = @"已安装";
        badge.textColor = UIColor.systemGreenColor;
    } else {
        badge.text = [NSString stringWithFormat:@"%.0f MB", info.approxSize / 1048576.0];
        badge.textColor = UIColor.secondaryLabelColor;
    }
    cell.accessoryView = badge;
    return cell;
}

#pragma mark - 操作

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;

    if (indexPath.section == 0) {
        SPToolchainInstaller *inst = [SPToolchainInstaller shared];
        if (inst.isInstalled) return;
        [self confirmInstall];
        return;
    }

    if (indexPath.row >= (NSInteger)self.items.count) return;
    SPComponentInfo *info = self.items[indexPath.row];
    if (info.isInstalled) {
        [self confirmRemove:info];
        return;
    }
    [self download:info];
}

- (void)confirmInstall {
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    if (!inst.hasBundledToolchain) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未内置工具链"
            message:@"这个包没有附带工具链。请先在「可安装组件」里下载「Theos 基础」。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    self.busy = YES;
    [inst installWithProgress:^(CGFloat fraction, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"安装中 %.0f%%", fraction * 100];
        });
    } completion:^(BOOL ok, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.title = @"Theos 工具链";
            [self reload];
            if (!ok) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"安装失败"
                    message:error.localizedDescription ?: @"未知错误"
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
    }];
}

- (void)download:(SPComponentInfo *)info {
    self.busy = YES;
    [[SPToolchainDownloader shared] download:info.component progress:^(CGFloat fraction, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"%@ %.0f%%", info.title, fraction * 100];
        });
    } completion:^(BOOL ok, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.title = @"Theos 工具链";
            [self reload];
            if (!ok) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"下载失败"
                    message:error.localizedDescription ?: @"请检查网络后重试"
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
    }];
}

- (void)confirmRemove:(SPComponentInfo *)info {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"移除组件"
        message:[NSString stringWithFormat:@"确定移除「%@」？删除后需要重新下载。", info.title]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        // downloader 有 remove:，之前 UI 却说「暂不支持」，两边不一致。
        // SDK 只会删自己的 sdks/iPhoneOS*.sdk，不会动工具链根目录。
        [[SPToolchainDownloader shared] remove:info.component];
        [self reload];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                           self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

@end

UIViewController *WBTheosToolsController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBTheosToolsListController new]];
}

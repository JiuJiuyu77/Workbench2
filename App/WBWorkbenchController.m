//
//  WBWorkbenchController.m
//  Workbench —— 底部「工作台」
//

#import "WBWorkbenchController.h"
#import "WorkbenchHealth.h"
#import "SPToolchainInstaller.h"
#import "SPJIT.h"
#import "SPCompat.h"
#import "GlassSupport.h"
#import "StorageSpace.h"
#import "WBRemoteController.h"
#import "WBReverseController.h"
#import "Runtime/Sandbox/TFAIISHHub.h"

extern UIViewController *WBStudioCrashTools(void);
extern UIViewController *TFAIClassDumpController(void);

@interface WBWorkbenchViewController : UITableViewController
@end

@implementation WBWorkbenchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"工作台";
    // dylix 卡片列表：去分隔线、行高自适应。
    TMCCardTableStyle(self.tableView);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(jitStatusChanged:)
                                                 name:@"SPJITStatusChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)jitStatusChanged:(NSNotification *)note {
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // JIT 首次进入时后台探测（probe 内部已切后台队列，不会卡主线程）。
    if (![SPJIT shared].lastProbe) [[SPJIT shared] probe];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"状态" : @"工具";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"构建统一走内置 Work1 工具链（Theos / make），不再使用进程内编译。" : nil;
}

- (NSString *)obfuscationName {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:@"WorkbenchObfuscation"];
    NSArray *names = @[@"关闭", @"轻度 · indbr+cse", @"均衡 · +icall", @"强力 · 全部 pass", @"自定义 pass"];
    return names[(NSUInteger)MIN(MAX(value, 0), 4)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WBWorkbenchCard";
    TMCCardCell *cell = [TMCCardCell cellInTable:tableView reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;

    if (indexPath.section == 0) {
        SPToolchainInstaller *installer = [SPToolchainInstaller shared];
        if (indexPath.row == 0) {
            [cell configureWithTitle:@"工具链"
                              detail:(installer.isInstalled
                                      ? [NSString stringWithFormat:@"Theos 就绪 · %@", installer.theosPath.lastPathComponent ?: @""]
                                      : @"未就绪 · 到「设置 → 工具链」安装")
                              symbol:@"wrench.and.screwdriver.fill"
                                tint:(installer.isInstalled ? UIColor.systemGreenColor : UIColor.systemOrangeColor)];
        } else if (indexPath.row == 1) {
            [cell configureWithTitle:@"混淆强度" detail:self.obfuscationName
                              symbol:@"shield.lefthalf.filled" tint:UIColor.systemIndigoColor];
        } else {
            [cell configureWithTitle:@"JIT 可执行内存" detail:[SPJIT shared].statusText
                              symbol:@"bolt.fill"
                                tint:([SPJIT shared].isEnabled ? UIColor.systemGreenColor : UIColor.systemOrangeColor)];
        }
        return cell;
    }

    NSArray *titles = @[@"快速构建测试", @"环境自检", @"逆向工作台", @"IPA 头文件导出", @"崩溃分析"];
    NSArray *details = @[@"编译内置样例 tweak，验证工具链", @"工具链 / 运行时 / 运行环境 / 磁盘", @"分析架构、符号、注入 dylib", @"从 ipa 导出头文件并分享", @"导入 .ips 与符号档案"];
    NSArray *icons = @[@"hammer.fill", @"checkmark.seal.fill", @"binoculars.fill", @"doc.text.magnifyingglass", @"waveform.path.ecg"];
    if (indexPath.row >= (NSInteger)titles.count) return cell;
    [cell configureWithTitle:titles[indexPath.row] detail:details[indexPath.row]
                      symbol:icons[indexPath.row] tint:UIColor.systemBlueColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row == 0) {
        WBHealthRunQuickBuild(self);
        return;
    }
    UIViewController *page = nil;
    switch (indexPath.row) {
        case 1: page = WBHealthController(); break;
        case 2: page = WBReverseController(); break;
        case 3: page = TFAIClassDumpController(); break;
        case 4: page = WBStudioCrashTools(); break;

        default: break;
    }
    if ([page isKindOfClass:UINavigationController.class]) page = ((UINavigationController *)page).viewControllers.firstObject;
    if (page) [self.navigationController pushViewController:page animated:YES];
}

@end

UIViewController *WBWorkbenchController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBWorkbenchViewController new]];
}

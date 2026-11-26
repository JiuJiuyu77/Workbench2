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

@interface WBWorkbenchViewController : UITableViewController
@end

@implementation WBWorkbenchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"工作台";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 62;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 8;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"状态" : @"工具";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"构建统一走内置 Work1 工具链（Theos / make），不再使用进程内编译。" : nil;
}

- (NSString *)obfuscationName {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:@"WorkbenchObfuscation"];
    NSArray *names = @[@"关闭", @"轻度 · indbr+cse", @"均衡 · +icall", @"强力 · 全部 pass"];
    return names[(NSUInteger)MIN(MAX(value, 0), 3)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WBWorkbenchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (indexPath.section == 0) {
        SPToolchainInstaller *installer = [SPToolchainInstaller shared];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"工具链";
            cell.detailTextLabel.text = installer.isInstalled
                ? [NSString stringWithFormat:@"Theos 就绪 · %@", installer.theosPath.lastPathComponent ?: @""]
                : @"未就绪 · 到「设置 → 工具链」安装";
            cell.imageView.image = [UIImage systemImageNamed:@"wrench.and.screwdriver.fill"];
            cell.imageView.tintColor = installer.isInstalled ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"混淆强度";
            cell.detailTextLabel.text = self.obfuscationName;
            cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
            cell.imageView.tintColor = UIColor.systemIndigoColor;
        } else {
            cell.textLabel.text = @"JIT 可执行内存";
            cell.detailTextLabel.text = [SPJIT shared].statusText;
            cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
            cell.imageView.tintColor = [SPJIT shared].isEnabled ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        }
        return cell;
    }

    NSArray *titles = @[@"快速构建测试", @"环境自检", @"逆向工作台", @"IPA 头文件导出", @"崩溃分析", @"安装工具", @"存储空间", @"远程工作台"];
    NSArray *details = @[@"编译内置样例 tweak，验证工具链", @"工具链 / 运行时 / 运行环境 / 磁盘", @"分析架构、符号、注入 dylib", @"从 ipa 导出头文件并分享", @"导入 .ips 与符号档案", @"按需安装 Linux 工具与 SDK", @"查看占用并清理缓存", @"SSH 远程构建与局域网工作台"];
    NSArray *icons = @[@"hammer.fill", @"checkmark.seal.fill", @"binoculars.fill", @"doc.text.magnifyingglass", @"waveform.path.ecg", @"shippingbox.fill", @"internaldrive.fill", @"network"];
    cell.textLabel.text = titles[indexPath.row];
    cell.detailTextLabel.text = details[indexPath.row];
    cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];
    cell.imageView.tintColor = UIColor.systemBlueColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
        case 5: page = TFAIISHToolsController(nil); break;
        case 6: page = TMCStorageController(); break;
        case 7: page = WBRemoteController(); break;
        default: break;
    }
    if ([page isKindOfClass:UINavigationController.class]) page = ((UINavigationController *)page).viewControllers.firstObject;
    if (page) [self.navigationController pushViewController:page animated:YES];
}

@end

UIViewController *WBWorkbenchController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBWorkbenchViewController new]];
}

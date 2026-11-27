//
//  WBToolsController.m
//  Workbench —— 实验能力与前缀工具（dylix 界面风格）
//

#import "WBToolsController.h"
#import "SPJIT.h"
#import "SPAOJIT.h"
#import "SPIShell.h"
#import "SPCompat.h"
#import "GlassSupport.h"

@interface WBToolsViewController : UITableViewController
@end

@implementation WBToolsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"执行环境";
    TMCCardTableStyle(self.tableView);
    // JIT 探测在后台完成，通过通知回主线程刷新这一页。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(jitStatusChanged:)
                                                 name:@"SPJITStatusChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 页面第一次打开时主动探测一次；probe 内部已经切到后台队列，
    // 主线程不会再被 runSyncShell / helper 启动阻塞。
    if (![SPJIT shared].lastProbe) [[SPJIT shared] probe];
    [self.tableView reloadData];
}

- (void)jitStatusChanged:(NSNotification *)note {
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"执行加速" : @"状态";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"JIT 让编译期生成的可执行内存真正可跑；AOJIT 把简单命令拆成 argv 直接 spawn，跳过 shell 解析；iSH 提供 Alpine 沙盒，仅在不支持的系统命令缺失时启用。";
    }
    return @"开关改动立即生效，构建时自动应用。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"WBToolsCard";
    TMCCardCell *cell = [TMCCardCell cellInTable:tableView reuseIdentifier:cid];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;

    if (indexPath.section == 1 && indexPath.row == 1) {
        BOOL enabled = [SPJIT shared].isEnabled;
        BOOL canRequest = [SPJIT shared].canRequestTrollStoreJIT;
        [cell configureWithTitle:@"JIT 授权"
                          detail:(enabled ? @"当前已可用，无需重复授权"
                                   : (canRequest ? @"点一下让 TrollStore 从外部附加（enable-jit）"
                                                 : @"本机没有 TrollStore 授权入口"))
                          symbol:@"checkmark.shield.fill"
                            tint:(enabled ? UIColor.systemGreenColor : UIColor.systemOrangeColor)];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if (indexPath.section == 1) {
        [cell configureWithTitle:@"能力概览"
                          detail:[NSString stringWithFormat:@"%@ · %@",
                                  [SPJIT shared].statusText ?: @"JIT 未知",
                                  [SPAOJIT shared].statusText ?: @"AOJIT 未知"]
                          symbol:@"info.circle.fill" tint:UIColor.secondaryLabelColor];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        return cell;
    }

    UISwitch *sw = [UISwitch new];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];

    if (indexPath.row == 0) {
        [cell configureWithTitle:@"JIT 可执行内存" detail:([SPJIT shared].statusText ?: @"未探测")
                          symbol:@"bolt.fill" tint:UIColor.systemBlueColor];
        sw.on = [SPJIT shared].userEnabled;
    } else if (indexPath.row == 1) {
        [cell configureWithTitle:@"AOJIT 命令快路径" detail:([SPAOJIT shared].statusText ?: @"未启用")
                          symbol:@"hare.fill" tint:UIColor.systemBlueColor];
        sw.on = [SPAOJIT shared].userEnabled;
    } else {
        [cell configureWithTitle:@"iSH 沙盒" detail:@"仅在命令缺失时启用（会拖慢构建）"
                          symbol:@"terminal.fill" tint:UIColor.systemGrayColor];
        sw.on = [NSUserDefaults.standardUserDefaults boolForKey:@"Workbench.ishellEnabled"];
    }
    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || indexPath.row != 1) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"JIT 授权"
                                                                   message:[SPJIT shared].authorizationHint
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if ([SPJIT shared].canRequestTrollStoreJIT && ![SPJIT shared].isEnabled) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"授权 JIT（打开 TrollStore）"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [[SPJIT shared] requestJITAuthorization];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"重新探测" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        // probe 自带后台队列 + 完成通知，这里不要再用后台队列包一层。
        [[SPJIT shared] probe];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)toggle:(UISwitch *)sw {
    BOOL on = sw.isOn;
    if (sw.tag == 0) {
        [SPJIT shared].userEnabled = on;
        if (on) [[SPJIT shared] probe];
    } else if (sw.tag == 1) {
        [SPAOJIT shared].userEnabled = on;
    } else {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:@"Workbench.ishellEnabled"];
    }
    [self.tableView reloadData];
}

@end

UIViewController *WBToolsController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBToolsViewController new]];
}

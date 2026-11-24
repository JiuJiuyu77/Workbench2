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

@interface WBToolsController : UITableViewController
@end

@implementation WBToolsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"执行环境";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 64;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 1;
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
    static NSString *cid = @"WBToolsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;

    if (indexPath.section == 1) {
        cell.textLabel.text = @"能力概览";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                                     [SPJIT shared].statusText ?: @"JIT 未知",
                                     [SPAOJIT shared].statusText ?: @"AOJIT 未知"];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        return cell;
    }

    UISwitch *sw = [UISwitch new];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];

    if (indexPath.row == 0) {
        cell.textLabel.text = @"JIT 可执行内存";
        cell.detailTextLabel.text = [SPJIT shared].statusText ?: @"未探测";
        sw.on = [SPJIT shared].userEnabled;
        cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"AOJIT 命令快路径";
        cell.detailTextLabel.text = [SPAOJIT shared].statusText ?: @"未启用";
        sw.on = [SPAOJIT shared].userEnabled;
        cell.imageView.image = [UIImage systemImageNamed:@"hare.fill"];
    } else {
        cell.textLabel.text = @"iSH 沙盒";
        cell.detailTextLabel.text = @"仅在命令缺失时启用（会拖慢构建）";
        sw.on = [NSUserDefaults.standardUserDefaults boolForKey:@"Workbench.ishellEnabled"];
        cell.imageView.image = [UIImage systemImageNamed:@"terminal.fill"];
    }
    cell.accessoryView = sw;
    return cell;
}

- (void)toggle:(UISwitch *)sw {
    BOOL on = sw.isOn;
    if (sw.tag == 0) {
        [SPJIT shared].userEnabled = on;
        if (on) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [[SPJIT shared] probe];
                dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
            });
        }
    } else if (sw.tag == 1) {
        [SPAOJIT shared].userEnabled = on;
    } else {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:@"Workbench.ishellEnabled"];
    }
    [self.tableView reloadData];
}

@end

UIViewController *WBToolsController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBToolsController new]];
}

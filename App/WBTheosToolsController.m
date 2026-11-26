//
//  WBTheosToolsController.m
//  Workbench —— Theos 工具链管理（dylix 界面风格）
//

#import "WBTheosToolsController.h"
#import "SPToolchainInstaller.h"
#import "SPToolchainDownloader.h"
#import "SPCompat.h"
#import "GlassSupport.h"

@interface WBTheosToolsListController : UITableViewController
@property (nonatomic, strong) NSArray<SPComponentInfo *> *items;
@property (nonatomic, assign) BOOL busy;
@end

@implementation WBTheosToolsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theos 工具链";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 64;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(reload)];
    [self reload];
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
    static NSString *cid = @"WBTheosCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;

    if (indexPath.section == 2) {
        NSArray<NSString *> *row = WBInstalledVersions()[(NSUInteger)indexPath.row];
        cell.textLabel.text = row[0];
        cell.detailTextLabel.text = row[1];
        cell.detailTextLabel.numberOfLines = 2;
        cell.imageView.image = [UIImage systemImageNamed:@"number.circle"];
        cell.imageView.tintColor = [row[1] isEqualToString:@"未安装"] ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        return cell;
    }
    if (indexPath.section == 0) {
        SPToolchainInstaller *inst = [SPToolchainInstaller shared];
        cell.textLabel.text = inst.isInstalled ? @"已安装" : (inst.hasBundledToolchain ? @"待安装" : @"未安装");
        cell.detailTextLabel.text = inst.isInstalled ? inst.installRoot : @"点此安装内置工具链";
        cell.textLabel.textColor = inst.isInstalled ? UIColor.labelColor : UIColor.systemOrangeColor;
        cell.selectionStyle = inst.isInstalled ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        return cell;
    }

    SPComponentInfo *info = self.items[indexPath.row];
    cell.textLabel.text = info.title;
    cell.detailTextLabel.text = info.detail;
    cell.textLabel.textColor = UIColor.labelColor;
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

    if (indexPath.section == 2) {
        NSArray<NSString *> *row = WBInstalledVersions()[(NSUInteger)indexPath.row];
        cell.textLabel.text = row[0];
        cell.detailTextLabel.text = row[1];
        cell.detailTextLabel.numberOfLines = 2;
        cell.imageView.image = [UIImage systemImageNamed:@"number.circle"];
        cell.imageView.tintColor = [row[1] isEqualToString:@"未安装"] ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        return cell;
    }
    if (indexPath.section == 0) {
        SPToolchainInstaller *inst = [SPToolchainInstaller shared];
        if (inst.isInstalled) return;
        [self confirmInstall];
        return;
    }

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
        // 下载器没有提供卸载接口，这里只提示，避免误删
        UIAlertController *b = [UIAlertController alertControllerWithTitle:@"暂不支持移除"
            message:@"当前版本只支持安装与覆盖。需要彻底清理请卸载 App。"
            preferredStyle:UIAlertControllerStyleAlert];
        [b addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:b animated:YES completion:nil];
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

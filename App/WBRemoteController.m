//
//  WBRemoteController.m
//  Workbench —— 远程构建与局域网工作台（dylix 界面风格）
//

#import "WBRemoteController.h"
#import "SPRemoteServer.h"
#import "SPCompat.h"
#import "GlassSupport.h"

@interface WBRemoteController () <UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *serverSwitch;
@property (nonatomic, strong) UITextField *hostField;
@property (nonatomic, strong) UITextField *userField;
@property (nonatomic, strong) UITextField *portField;
@end

@implementation WBRemoteController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"远程构建";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 60;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : (section == 1 ? 3 : 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"局域网工作台", @"SSH 远程构建", @"说明"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"在手机本地起一个 HTTP 服务，同一 Wi-Fi 下的电脑浏览器可直接浏览工程、看构建日志。默认关闭，只监听局域网。";
    }
    if (section == 1) {
        return @"填写后，构建页可选择「远程构建」，命令通过 SSH 在目标机器上执行，产物回传到手机。主机需已装 Theos 与 clang。";
    }
    return @"SSH 目前使用系统 ssh 客户端，需目标机已配置密钥或允许密码登录。所有连接信息只保存在本机。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"WBRemoteCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;

    if (indexPath.section == 0) {
        SPRemoteServer *srv = [SPRemoteServer shared];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"启用工作台";
            cell.detailTextLabel.text = srv.statusText;
            UISwitch *sw = [UISwitch new];
            sw.on = srv.isRunning;
            [sw addTarget:self action:@selector(toggleServer:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.textLabel.text = srv.baseURL ?: @"未启动";
            cell.detailTextLabel.text = srv.isRunning
                ? [NSString stringWithFormat:@"访问码：%@", srv.accessCode ?: @"-"]
                : @"启动后显示地址与访问码";
            cell.selectionStyle = srv.isRunning ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"主机";
            cell.detailTextLabel.text = @"IP 或域名";
            cell.accessoryView = self.hostField;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"用户名";
            cell.detailTextLabel.text = @"SSH 登录名";
            cell.accessoryView = self.userField;
        } else {
            cell.textLabel.text = @"端口";
            cell.detailTextLabel.text = @"默认 22";
            cell.accessoryView = self.portField;
        }
        (void)d;
        return cell;
    }

    cell.textLabel.text = @"测试连接";
    cell.detailTextLabel.text = @"执行 ssh -V 并尝试握手";
    cell.textLabel.textColor = UIColor.systemBlueColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - 控件

- (UITextField *)fieldWith:(NSString *)text placeholder:(NSString *)ph width:(CGFloat)w {
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, w, 32)];
    tf.text = text;
    tf.placeholder = ph;
    tf.textAlignment = NSTextAlignmentRight;
    tf.font = [UIFont systemFontOfSize:14];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.delegate = self;
    [tf addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    return tf;
}

- (UITextField *)hostField {
    if (!_hostField) {
        _hostField = [self fieldWith:[NSUserDefaults.standardUserDefaults stringForKey:@"Workbench.sshHost"]
                         placeholder:@"192.168.1.10" width:170];
        _hostField.keyboardType = UIKeyboardTypeURL;
    }
    return _hostField;
}

- (UITextField *)userField {
    if (!_userField) {
        NSString *u = [NSUserDefaults.standardUserDefaults stringForKey:@"Workbench.sshUser"];
        _userField = [self fieldWith:u.length ? u : @"root" placeholder:@"root" width:170];
    }
    return _userField;
}

- (UITextField *)portField {
    if (!_portField) {
        NSInteger p = [NSUserDefaults.standardUserDefaults integerForKey:@"Workbench.sshPort"];
        _portField = [self fieldWith:(p > 0 ? [NSString stringWithFormat:@"%ld", (long)p] : @"22")
                         placeholder:@"22" width:170];
        _portField.keyboardType = UIKeyboardTypeNumberPad;
    }
    return _portField;
}

- (void)fieldChanged:(UITextField *)tf {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (tf == _hostField) [d setObject:tf.text ?: @"" forKey:@"Workbench.sshHost"];
    else if (tf == _userField) [d setObject:tf.text ?: @"root" forKey:@"Workbench.sshUser"];
    else if (tf == _portField) [d setInteger:(tf.text.integerValue > 0 ? tf.text.integerValue : 22) forKey:@"Workbench.sshPort"];
    [d synchronize];
}

#pragma mark - 动作

- (void)toggleServer:(UISwitch *)sw {
    SPRemoteServer *srv = [SPRemoteServer shared];
    if (sw.isOn) {
        NSError *err = nil;
        if (![srv startWithPort:8787 error:&err]) {
            sw.on = NO;
            [self alert:@"启动失败" msg:err.localizedDescription ?: @"端口被占用或权限不足"];
        }
    } else {
        [srv stop];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 1) {
        SPRemoteServer *srv = [SPRemoteServer shared];
        if (!srv.isRunning) return;
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@  (%@)", srv.baseURL ?: @"", srv.accessCode ?: @""];
        [self alert:@"已复制" msg:@"地址与访问码已复制到剪贴板。"];
        return;
    }
    if (indexPath.section == 1) {
        [self.view endEditing:YES];
        return;
    }
    if (indexPath.section == 2) {
        [self testConnection];
    }
}

- (void)testConnection {
    NSString *host = self.hostField.text ?: @"";
    NSString *user = self.userField.text ?: @"root";
    NSInteger port = self.portField.text.integerValue > 0 ? self.portField.text.integerValue : 22;
    if (host.length == 0) {
        [self alert:@"缺少主机" msg:@"请先填写 SSH 主机地址。"];
        return;
    }
    NSString *script = [NSString stringWithFormat:
        @"ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8 -p %ld %@ %@ 'uname -a' 2>&1",
        (long)port, [SPUtil shellQuote:user], [SPUtil shellQuote:host]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPCommandResult *r = [SPSession runSyncShell:script environment:@{} cwd:NSTemporaryDirectory() timeout:20];
        NSString *text = r.stdoutText ?: @"";
        if (r.stderrText.length) text = [text stringByAppendingFormat:@"\n%@", r.stderrText];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:(r.exitCode == 0 ? @"连接成功" : @"连接失败") msg:(text.length ? text : @"无输出")];
        });
    });
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self alert:title msg:msg]; });
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

UIViewController *WBRemoteController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBRemoteController new]];
}

//
//  WBReverseController.m
//  Workbench —— 逆向工作台（dylix 界面风格）
//

#import "WBReverseController.h"
#import "SPSession.h"
#import "SPCompat.h"
#import "SPToolchainInstaller.h"
#import "GlassSupport.h"

@interface WBReverseController () <UIDocumentPickerDelegate>
@property (nonatomic, copy, nullable) NSString *targetPath;
@property (nonatomic, strong) UITextView *output;
@property (nonatomic, assign) BOOL running;
@end

@implementation WBReverseController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"逆向工作台";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self action:@selector(pickFile)];
}

- (void)pickFile {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // 复制到沙盒，避免安全作用域 URL 失效
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dst error:NULL];
    NSError *err = nil;
    [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&err];
    if (err) {
        [self alert:@"导入失败" msg:err.localizedDescription];
        return;
    }
    self.targetPath = dst;
    [self.tableView reloadData];
}

#pragma mark - 表

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"目标文件" : @"分析动作";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"反汇编与符号需要 radare2（在「Theos 工具链」里下载逆向工具）。deb 解包使用 dpkg-deb，随工具链提供。全部在本机执行，不联网。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"WBRevCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;

    if (indexPath.section == 0) {
        cell.textLabel.text = self.targetPath.lastPathComponent ?: @"选择文件";
        cell.detailTextLabel.text = self.targetPath
            ? [NSString stringWithFormat:@"%.1f KB", ({ NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:self.targetPath error:NULL]; [a[@"NSFileSize"] doubleValue] / 1024.0; })]
            : @"支持 Mach-O / dylib / deb / zip";
        cell.textLabel.textColor = self.targetPath ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSArray *titles = @[@"基本信息（file）", @"CPU 架构", @"符号表", @"可读字符串", @"ARM64 反汇编", @"解包 deb / 压缩包"];
    NSArray *details = @[@"文件类型与加密状态", @"arch / cputype", @"rabin2 -s", @"rabin2 -zz", @"r2 前 200 行", @"dpkg-deb -x 到临时目录"];
    cell.textLabel.text = titles[indexPath.row];
    cell.detailTextLabel.text = details[indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) { [self pickFile]; return; }
    if (!self.targetPath) { [self alert:@"还没有选文件" msg:@"先在上方选择要分析的文件。"]; return; }
    if (self.running) return;

    NSString *path = [SPUtil shellQuote:self.targetPath];
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    NSString *revBin = inst.reverseBinDir ?: @"";

    NSString *script = nil;
    switch (indexPath.row) {
        case 0:
            script = [NSString stringWithFormat:@"file %@", path];
            break;
        case 1:
            script = [NSString stringWithFormat:@"%@/rabin2 -I %@ 2>/dev/null || file %@",
                      [SPUtil shellQuote:revBin], path, path];
            break;
        case 2:
            script = [NSString stringWithFormat:@"%@/rabin2 -s %@ | head -120", [SPUtil shellQuote:revBin], path];
            break;
        case 3:
            script = [NSString stringWithFormat:@"%@/rabin2 -zz %@ | head -120", [SPUtil shellQuote:revBin], path];
            break;
        case 4:
            script = [NSString stringWithFormat:@"%@/r2 -q -c 'aa; pdf @@ sym.*' %@ 2>/dev/null | head -200",
                      [SPUtil shellQuote:revBin], path];
            break;
        case 5:
            script = [NSString stringWithFormat:
                      @"D=$(mktemp -d); case %@ in *.deb) dpkg-deb -x %@ $D || tar -xf %@ -C $D;; *.zip) unzip -oq %@ -d $D;; *.gz) tar -xzf %@ -C $D;; *.xz) tar -xJf %@ -C $D;; *) tar -xf %@ -C $D;; esac; ls -la $D | head -50",
                      path, path, path, path, path, path, path];
            break;
    }
    [self run:script];
}

#pragma mark - 执行

- (void)run:(NSString *)script {
    self.running = YES;
    [self showOutput:@"执行中…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPCommandResult *r = [SPSession runSyncShell:script
                                         environment:[SPToolchainInstaller shared].runtimeEnvironment
                                                 cwd:NSTemporaryDirectory()
                                             timeout:120];
        NSString *text = r.stdoutText ?: @"";
        if (r.stderrText.length) {
            text = [text stringByAppendingFormat:@"\n[stderr]\n%@", r.stderrText];
        }
        if (r.timedOut) text = [text stringByAppendingString:@"\n[超时]"];
        if (text.length == 0) text = @"无输出";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            [self showOutput:text];
        });
    });
}

- (void)showOutput:(NSString *)text {
    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.text = text;
    tv.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    UIViewController *vc = [UIViewController new];
    vc.title = @"输出";
    vc.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [vc.view addSubview:tv];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-8],
    ]];
    [self.navigationController pushViewController:vc animated:YES];
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

UIViewController *WBReverseController(void) {
    return [[TMCNavigationController alloc] initWithRootViewController:[WBReverseController new]];
}

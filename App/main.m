#import "DocumentPresentation.h"
#import "Runtime/Resources/DXAppUpdate.h"
#import "Runtime/Backup/DXBackup.h"
#import "Runtime/Build/TFAIBuildCheckpoint.h"
#import "Runtime/Build/TFAIBuildQueue.h"
#import "Runtime/Background/TFScreenAwake.h"
#import "StorageSpace.h"
#import "Remote/DXRemoteService.h"
#import "Runtime/Background/TFAIBackground.h"
#import "Runtime/Background/TFAINotifications.h"
#import "RuntimeDiagnostics.h"
#import "Runtime/CrashGuard.h"
#import "GlassSupport.h"
#import <UIKit/UIKit.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <pthread.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "DebPackage.h"
#import "PackageLinking.h"
#import "DylibSignature.h"
#import "OutputNaming.h"
#import "ArchiveImport.h"
#import "SDKResources.h"
#import "Incoming/TFIncoming.h"
#import "GitAutomation.h"
#import "LinkSupport.h"
#import "../Vendor/MBProgressHUD/MBProgressHUD.h"

static void TMCLog(FILE *stream, const char *format, ...) {
 if(!stream)return;va_list args;va_start(args,format);char *buffer=NULL;int count=vasprintf(&buffer,format,args);va_end(args);NSString *message=count>=0?[[NSString alloc] initWithBytes:buffer length:(NSUInteger)count encoding:NSUTF8StringEncoding]:nil;free(buffer);if(!message)message=@"日志编码错误";
 NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];formatter.dateFormat=@"HH:mm:ss.SSS";NSString *stamp=[formatter stringFromDate:NSDate.date];[message enumerateSubstringsInRange:NSMakeRange(0,message.length) options:NSStringEnumerationByLines usingBlock:^(NSString *line,NSRange range,NSRange enclosing,BOOL *stop){fprintf(stream,"[%s] %s\n",stamp.UTF8String,line.UTF8String);}];fflush(stream);
}

static BOOL TMCBuildRunning = NO;
BOOL TMCBuildIsRunning(void){NSCAssert(NSThread.isMainThread,@"Main-thread build state");return TMCBuildRunning;}

static NSString *projectPath(NSString *root, NSString *relative) {
    if (![relative isKindOfClass:NSString.class] || relative.isAbsolutePath) return nil;
    NSString *base = root.stringByStandardizingPath;
    NSString *path = [root stringByAppendingPathComponent:relative].stringByStandardizingPath;
    return [path hasPrefix:[base stringByAppendingString:@"/"]] ? path : nil;
}
static int runTool(NSArray<NSString *> *arguments, FILE *input, FILE *log);
#include "SymbolProcessing.inc"
static NSDictionary *projectConfig(NSString *root) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"MobileCompiler.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSArray<NSString *> *sourcePaths(NSString *root) {
    NSDictionary *config = projectConfig(root);
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *names = [config[@"sources"] isKindOfClass:NSArray.class] ? config[@"sources"] : [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSString *path = projectPath(root, name);
        if (!path || ![@[@"x", @"xm", @"m", @"mm", @"c", @"cpp"] containsObject:path.pathExtension.lowercaseString]) continue;
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory) [paths addObject:path];
    }
    return paths;
}
#import "CompilerController.h"
#import "SPBuilder.h"
#import "SPCompat.h"
#import "SPSession.h"
#import "SPToolchainInstaller.h"

// 工具链子进程执行：符号处理（dsymutil/strip）等仍需要跑真实二进制。
// 全部经 SPSession 的 posix_spawn + 工具链环境，不再走进程内 ios_system。
static int runTool(NSArray<NSString *> *arguments, FILE *input, FILE *log) {
    if (!arguments.count) return 64;
    NSMutableArray *quoted = [NSMutableArray arrayWithCapacity:arguments.count];
    for (NSString *argument in arguments) [quoted addObject:[SPUtil shellQuote:argument]];
    NSDictionary *env = [[SPToolchainInstaller shared] runtimeEnvironment];
    SPCommandResult *result = [SPSession runSyncShell:[quoted componentsJoinedByString:@" "]
                                          environment:env
                                                  cwd:NSTemporaryDirectory()
                                              timeout:600];
    if (result.stdoutText.length) fprintf(log, "%s", result.stdoutText.UTF8String);
    if (result.stderrText.length) fprintf(log, "%s", result.stderrText.UTF8String);
    fflush(log);
    (void)input;
    return result.exitCode;
}


#import "SPModels.h"
#import "SPToolchain.h"
#import "SPToolchainInstaller.h"
#import "Studio.h"
#import "GitUI.h"

// App-owned Documents needs no File Provider hand-off. Browse it directly.
#if TARGET_OS_SIMULATOR
extern UIViewController *TMCStorageBackup258Regression(void);
#endif
@interface TMCLocalFolders : UITableViewController
@property NSString *directory;
@property NSString *boundary;
@property NSArray<NSDictionary *> *entries;
@property(copy) void (^selected)(NSString *);
@end
@implementation TMCLocalFolders
- (void)viewDidLoad{
 [super viewDidLoad];self.title=[self.directory isEqual:self.boundary]?@"Workbench 本机目录":self.directory.lastPathComponent;
 self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"打开" style:UIBarButtonItemStyleDone target:self action:@selector(choose)];self.navigationItem.rightBarButtonItem.accessibilityLabel=@"打开当前工程文件夹";
 self.navigationItem.rightBarButtonItem.enabled=![self.directory isEqual:self.boundary];
 if([self.directory isEqual:self.boundary])self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
 NSMutableArray *items=[NSMutableArray new];NSError *error=nil;
 NSArray *urls=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.directory] includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&error];
 for(NSURL *url in urls){NSDictionary *v=[url resourceValuesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] error:nil];NSString *name=url.lastPathComponent;if([v[NSURLIsSymbolicLinkKey] boolValue]||[name hasPrefix:@"Build-"]||[name hasPrefix:@"Snapshot-"])continue;[items addObject:@{@"name":name,@"directory":v[NSURLIsDirectoryKey]?:@NO}];}
 [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){if([a[@"directory"] boolValue]!=[b[@"directory"] boolValue])return [a[@"directory"] boolValue]?NSOrderedAscending:NSOrderedDescending;return [a[@"name"] localizedStandardCompare:b[@"name"]];}];self.entries=items;
 if(error||!items.count){UILabel *empty=[UILabel new];empty.text=error.localizedDescription?:@"此文件夹为空。请先在“文件”App 中复制工程到 Workbench。";empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.textColor=UIColor.secondaryLabelColor;self.tableView.backgroundView=empty;}
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return @"进入工程文件夹，再点右上角“打开” · 本机直接读取";}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.entries.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index{NSDictionary *item=self.entries[index.row];BOOL directory=[item[@"directory"] boolValue];UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.text=item[@"name"];cell.textLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;cell.imageView.image=[UIImage systemImageNamed:directory?@"folder":@"doc.text"];cell.imageView.tintColor=directory?UIColor.systemOrangeColor:UIColor.secondaryLabelColor;cell.accessoryType=directory?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=directory?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.detailTextLabel.text=directory?@"点击进入":@"工程文件";return cell;}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index{[tableView deselectRowAtIndexPath:index animated:YES];NSDictionary *item=self.entries[index.row];if(![item[@"directory"] boolValue])return;TMCLocalFolders *next=[TMCLocalFolders new];next.directory=[self.directory stringByAppendingPathComponent:item[@"name"]];next.boundary=self.boundary;next.selected=self.selected;[self.navigationController pushViewController:next animated:YES];}
- (void)choose{if([self.directory isEqual:self.boundary])return;if(self.selected)self.selected(self.directory);}
- (void)cancel{[self dismissViewControllerAnimated:YES completion:nil];}
@end

@interface TMCArchiveProjectList : UITableViewController
@property NSArray<NSDictionary *> *projects;
@property(copy) void (^selected)(NSDictionary *);
@property(copy) void (^cancelled)(void);
@property BOOL completed;
@end
@implementation TMCArchiveProjectList
- (void)viewDidLoad {
    [super viewDidLoad];self.title=[NSString stringWithFormat:@"选择工程（%lu）",(unsigned long)self.projects.count];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return @"压缩包中发现多个工程，选择一个导入";}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.projects.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    NSDictionary *project=self.projects[index.row];UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=project[@"name"];cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@ 个源码",project[@"relative"],project[@"sources"]];cell.detailTextLabel.numberOfLines=2;
    cell.imageView.image=[UIImage systemImageNamed:@"folder"];cell.imageView.tintColor=UIColor.systemOrangeColor;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];if(self.completed)return;self.completed=YES;
    NSDictionary *project=self.projects[index.row];[self dismissViewControllerAnimated:YES completion:^{if(self.selected)self.selected(project);}];
}
- (void)cancel {if(self.completed)return;self.completed=YES;[self dismissViewControllerAnimated:YES completion:^{if(self.cancelled)self.cancelled();}];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(!self.completed&&(!self.navigationController.presentingViewController||self.navigationController.isBeingDismissed)){self.completed=YES;if(self.cancelled)self.cancelled();}}
@end

@implementation CompilerController

#pragma mark - 新架构构建（Theos + make）

/// 尝试用新架构（SPBuilder / Theos + make）构建。
/// 返回 YES 表示已由新架构完成；NO 表示前置条件不满足或构建失败，调用方继续走内嵌编译。
/// 说明：dylix 原有的进程内 LLVM 编译保留为回退路径，仅在异常时使用，
///      并在失败弹窗里明确告知用户「已自动回退」。
- (BOOL)tryTheosBuildProject:(NSString *)projectDirectory buildDir:(NSString *)build {
    SPToolchainInstaller *inst = [SPToolchainInstaller shared];
    if (!inst.isInstalled) {
        TMCLog(NULL, "新架构：Theos 工具链未安装，回退内嵌编译\n");
        return NO;
    }

    NSError *error = nil;
    SPToolchainProfile *profile = [[SPToolchain shared] localProfileWithSDK:nil error:&error];
    if (!profile || profile.theosPath.length == 0) {
        TMCLog(NULL, "新架构：工具链 profile 不可用（%s），回退内嵌编译\n",
               (error.localizedDescription ?: @"未知原因").UTF8String);
        return NO;
    }

    SPProject *project = [SPProject projectAtPath:projectDirectory error:&error];
    if (!project || !project.isTheosProject) {
        TMCLog(NULL, "新架构：工程无 Makefile，改用内嵌编译\n");
        return NO;
    }

    TMCLog(NULL, "新架构：使用 Theos 构建（%s）\n", profile.theosPath.UTF8String);
    __block BOOL succeeded = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SPBuilder buildProject:project options:project.options profile:profile
                     onLine:^(NSString *line, SPLogLevel level) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!line.length) return;
            self.console.text = [self.console.text stringByAppendingFormat:@"%@\n", line];
        });
    } onFinish:^(SPJob *job) {
        succeeded = (job.exitCode == 0);
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3600 * NSEC_PER_SEC)));
    return succeeded;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本地编译验证";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.console = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.console.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.console.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.console.editable = NO;
    TMCEnableTextLinks(self.console);
    [self.view addSubview:self.console];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"运行" style:UIBarButtonItemStylePlain target:self action:@selector(runProof)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导入源码" style:UIBarButtonItemStylePlain target:self action:@selector(importSource)];
    self.toolbarItems = @[[[UIBarButtonItem alloc] initWithTitle:@"导出结果" style:UIBarButtonItemStylePlain target:self action:@selector(exportResult)]];
    self.navigationController.toolbarHidden = NO;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *previous = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:documents error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSDate *latest = NSDate.distantPast;
    for (NSString *name in previous) {
        if (![name hasPrefix:@"Build-"]) continue;
        NSString *path = [documents stringByAppendingPathComponent:name];
        NSDate *date = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (date && [date compare:latest] == NSOrderedDescending) { latest = date; self.lastBuild = path; }
    }
    self.console.text = @"Workbench · 技术验证版\n\n导入多源码工程文件夹，或点击运行构建内置 Objective-C 样本。\n\n目标：arm64 · iOS 15+ · Rootless .deb\n所有构建步骤在 App 进程内执行。";
    NSString *savedSource = [NSUserDefaults.standardUserDefaults stringForKey:@"ImportedSourceRelativePath"];
    if (savedSource) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *restored = [documents stringByAppendingPathComponent:savedSource];
        if ([NSFileManager.defaultManager fileExistsAtPath:restored]) {
            self.importedSource = restored;
            self.console.text = [self.console.text stringByAppendingFormat:@"\n\n已恢复导入源码：%@", restored.lastPathComponent];
        }
    }
    NSString *savedProject = [NSUserDefaults.standardUserDefaults stringForKey:@"ImportedProject"];
    if (savedProject) {
        NSString *path = [documents stringByAppendingPathComponent:savedProject];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) self.importedProject = path;
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--repeat-builds"]) {
        __weak typeof(self) weakSelf = self;
        __block NSMutableArray *runs = [NSMutableArray new];
        __block NSString *baseline = nil;
        self.buildCompletion = ^(BOOL success) {
            CompilerController *controller = weakSelf;
            if (!baseline) baseline = controller.importedProject;
            [runs addObject:@{@"success":@(success), @"build":controller.lastBuild ?: @""}];
            [[NSJSONSerialization dataWithJSONObject:runs options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"repeat-builds.json"] atomically:YES];
            BOOL expected = runs.count != 2 && runs.count != 4;
            if (success != expected || runs.count >= 10) return;
            if (runs.count == 1 || runs.count == 3) {
                NSString *fixture = [documents stringByAppendingPathComponent:@"RepeatFailureFixture"];
                [NSFileManager.defaultManager createDirectoryAtPath:fixture withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *code = runs.count == 1 ? @"invalid syntax here !!!" : @"int repeat_fixture(void) { return 1; }";
                [code writeToFile:[fixture stringByAppendingPathComponent:@"Fixture.c"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSDictionary *config = @{@"name":@"RepeatFailure", @"sources":@[@"Fixture.c"], @"package":@NO, @"frameworks":runs.count == 3 ? @[@"MissingFixtureFramework"] : @[]};
                [[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] writeToFile:[fixture stringByAppendingPathComponent:@"MobileCompiler.json"] atomically:YES];
                controller.importedProject = fixture;
            } else controller.importedProject = baseline;
            [controller runProof];
        };
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-test"]) [self runProof];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-test-project"]) {
#if TARGET_OS_SIMULATOR
        NSArray *testArguments = NSProcessInfo.processInfo.arguments;
        NSUInteger testPathIndex = [testArguments indexOfObject:@"--test-project-path"];
        if (testPathIndex != NSNotFound && testPathIndex + 1 < testArguments.count) {
            [self importURLs:@[[NSURL fileURLWithPath:testArguments[testPathIndex + 1] isDirectory:YES]]];
            return;
        }
#endif
        NSString *fixture = [NSProcessInfo.processInfo.arguments containsObject:@"--flex"] ? @"FLEXProject" : [NSProcessInfo.processInfo.arguments containsObject:@"--multi"] ? @"SampleMultiObjectiveC" : ([NSProcessInfo.processInfo.arguments containsObject:@"--generated-logos"] ? @"SampleLogosGenerated" : @"SampleObjectiveC");
        [self importURLs:@[[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:fixture]]];
    }

}
- (void)showImportMessage:(NSString *)message {
#if TARGET_OS_SIMULATOR
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--test-project-path"]) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:@{@"message":message ?: @"", @"imported":@([message hasPrefix:@"已导入"])} options:0 error:nil] writeToFile:[documents stringByAppendingPathComponent:@"TestImportResult.json"] atomically:YES];
    }
#endif
    self.console.text = message;
    if (self.importCompletion && [message hasPrefix:@"已导入"]) return;
    UIViewController *host=[self importHost];
    id<UIViewControllerTransitionCoordinator> transition=host.presentedViewController.transitionCoordinator?:host.transitionCoordinator;
    if(transition&&[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){dispatch_async(dispatch_get_main_queue(),^{[self showImportMessage:message];});}])return;
    if(host.presentedViewController){[host dismissViewControllerAnimated:YES completion:^{[self showImportMessage:message];}];return;}
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入结果" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [[self importHost] presentViewController:alert animated:YES completion:nil];
}
- (UIViewController *)importHost { return self.presentationHost ?: self; }
- (void)openFilePicker {
    if(self.activePicker)return;
    self.pickingArchive=NO;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection=YES;
    picker.shouldShowFileExtensions=YES;
    picker.delegate=self;
    picker.title=@"选择源码及配置文件";
    self.activePicker=picker;
    dispatch_async(dispatch_get_main_queue(), ^{[self presentPendingPicker];});
}
- (void)openArchivePicker {
    if(self.activePicker||self.importInProgress)return;
    self.pickingArchive=YES;
    // A generic type also exposes providers' unregistered .7z/.rar types.
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection=NO;picker.shouldShowFileExtensions=YES;picker.delegate=self;
    picker.title=@"选择压缩包 · ZIP / 7z / RAR / TAR";self.activePicker=picker;
    dispatch_async(dispatch_get_main_queue(),^{[self presentPendingPicker];});
}
- (void)presentPendingPicker {
    UIViewController *host=[self importHost];
    UIDocumentPickerViewController *picker=self.activePicker;
    if(!picker||picker.presentingViewController)return;
    id<UIViewControllerTransitionCoordinator> transition=host.presentedViewController.transitionCoordinator?:host.transitionCoordinator;
    if(transition&&[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){dispatch_async(dispatch_get_main_queue(),^{[self presentPendingPicker];});}])return;
    if(host.presentedViewController)return;
    [host presentViewController:picker animated:YES completion:^{picker.presentationController.delegate=self;}];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { self.activePicker=nil; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if(presentationController.presentedViewController==self.activePicker)self.activePicker=nil;
}
- (void)loadDocumentsProject {
    UIViewController *host=[self importHost];
    id<UIViewControllerTransitionCoordinator> transition=host.presentedViewController.transitionCoordinator?:host.transitionCoordinator;
    if(transition&&[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){dispatch_async(dispatch_get_main_queue(),^{[self loadDocumentsProject];});}])return;
    if(host.presentedViewController)return;
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    TMCLocalFolders *folders=[TMCLocalFolders new];folders.directory=documents;folders.boundary=documents;
    __weak typeof(self) weakSelf=self;
    folders.selected=^(NSString *path){typeof(self) owner=weakSelf;if(!owner)return;[[owner importHost] dismissViewControllerAnimated:YES completion:^{[owner importURLs:@[[NSURL fileURLWithPath:path isDirectory:YES]]];}];};
    UINavigationController *nav=[[TMCNavigationController alloc] initWithRootViewController:folders];
    [host presentViewController:nav animated:YES completion:nil];
}
- (void)importSource {
    UIViewController *host=[self importHost];
    if(host.presentedViewController)return;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"打开项目" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"从 ZIP / 压缩包导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openArchivePicker];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"选择源码及配置文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openFilePicker];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"从 App 内工程目录载入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){dispatch_async(dispatch_get_main_queue(),^{[self loadDocumentsProject];});}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=host.view;
    menu.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(host.view.bounds),CGRectGetMidY(host.view.bounds),1,1);
    [host presentViewController:menu animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(controller!=self.activePicker)return;
    self.activePicker=nil;
    if(self.pickingArchive){self.pickingArchive=NO;if(urls.count)[self importArchiveURL:urls.firstObject];return;}
    // Acquire security scopes immediately; provider work stays on the worker queue.
    [self importURLs:urls];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url?@[url]:@[]];
}
- (void)afterImportPresentation:(void (^)(void))completion {
    UIViewController *host=[self importHost];
    id<UIViewControllerTransitionCoordinator> transition=host.presentedViewController.transitionCoordinator?:host.transitionCoordinator;
    if(transition&&[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){dispatch_async(dispatch_get_main_queue(),^{[self afterImportPresentation:completion];});}])return;
    if(host.presentedViewController){[host dismissViewControllerAnimated:YES completion:^{[self afterImportPresentation:completion];}];return;}
    completion();
}
- (void)cancelArchive {[self.archiveProgress cancel];self.archiveHUD.button.enabled=NO;}
- (void)showArchiveHUD {
    if(self.archiveHUD)return;
    UIView *view=[self importHost].navigationController.view?:[self importHost].view;
    MBProgressHUD *hud=[MBProgressHUD showHUDAddedTo:view animated:YES];self.archiveHUD=hud;
    hud.removeFromSuperViewOnHide=YES;hud.label.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];hud.label.text=@"正在读取压缩包…";
    [hud.button setTitle:@"取消" forState:UIControlStateNormal];[hud.button addTarget:self action:@selector(cancelArchive) forControlEvents:UIControlEventTouchUpInside];
}
- (void)hideArchiveHUD {[self.archiveHUD hideAnimated:YES];self.archiveHUD=nil;}
- (void)cleanupArchive {
    [self hideArchiveHUD];
    if(self.archiveWorkRoot)[NSFileManager.defaultManager removeItemAtPath:self.archiveWorkRoot error:nil];
    self.archiveWorkRoot=nil;self.archiveInputPath=nil;self.archiveProjectName=nil;self.archiveProgress=nil;
}
- (void)importArchiveURL:(NSURL *)url {
    if(self.importInProgress)return;self.importInProgress=YES;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    self.archiveProgress=[NSProgress progressWithTotalUnitCount:1];
    [self afterImportPresentation:^{
      [self showArchiveHUD];
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *work=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ArchiveImport-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *input=[[work stringByAppendingPathComponent:@"Source"] stringByAppendingPathComponent:url.lastPathComponent.length?url.lastPathComponent:@"Project.archive"];
        NSError *error=nil;__block NSError *copyError=nil;
        if([fm createDirectoryAtPath:input.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]){
            NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
            [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *readURL){[fm copyItemAtURL:readURL toURL:[NSURL fileURLWithPath:input] error:&copyError];}];
        }
        if(scoped)[url stopAccessingSecurityScopedResource];error=error?:copyError;
        dispatch_async(dispatch_get_main_queue(),^{
            self.archiveWorkRoot=work;self.archiveInputPath=input;
            if(error||self.archiveProgress.cancelled){self.importInProgress=NO;[self cleanupArchive];if(error)[self showImportMessage:error.localizedDescription];return;}
            [self expandArchiveWithPassword:nil];
        });
      });
    }];
}
- (void)expandArchiveWithPassword:(NSString *)password {
    self.archiveProgress=[NSProgress progressWithTotalUnitCount:1];
    [self showArchiveHUD];self.archiveHUD.button.enabled=YES;
    NSString *expanded=[self.archiveWorkRoot stringByAppendingPathComponent:@"Expanded"];
    NSString *input=self.archiveInputPath;NSProgress *progress=self.archiveProgress;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        [NSFileManager.defaultManager removeItemAtPath:expanded error:nil];
        NSError *error=nil;__block NSTimeInterval updated=0;
        BOOL ok=TMCExtractArchive([NSURL fileURLWithPath:input],[NSURL fileURLWithPath:expanded],password,progress,^(NSUInteger files,unsigned long long bytes){
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(now-updated<.15)return;updated=now;
            dispatch_async(dispatch_get_main_queue(),^{if(self.archiveProgress==progress)self.archiveHUD.label.text=[NSString stringWithFormat:@"%lu 个条目 · %@",(unsigned long)files,[NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];});
        },&error);
        NSArray *projects=ok?TMCArchiveProjects(expanded,progress,&error):nil;
        dispatch_async(dispatch_get_main_queue(),^{
            if(progress.cancelled){self.importInProgress=NO;[self cleanupArchive];return;}
            if(!projects){
                [self hideArchiveHUD];
                if([error.domain isEqual:@"WorkbenchArchive"]&&error.code==TMCArchivePassword){[self requestArchivePassword:password.length>0];return;}
                self.importInProgress=NO;[self cleanupArchive];[self showImportMessage:error.localizedDescription?:@"压缩包识别失败"];return;
            }
            if(projects.count==1){[self importArchiveProject:projects.firstObject];return;}
            [self hideArchiveHUD];
            TMCArchiveProjectList *list=[[TMCArchiveProjectList alloc] initWithStyle:UITableViewStyleInsetGrouped];list.projects=projects;
            __weak typeof(self) weakSelf=self;
            list.selected=^(NSDictionary *project){[weakSelf importArchiveProject:project];};
            list.cancelled=^{weakSelf.importInProgress=NO;[weakSelf cleanupArchive];};
            [[self importHost] presentViewController:[[TMCNavigationController alloc] initWithRootViewController:list] animated:YES completion:nil];
        });
    });
}
- (void)requestArchivePassword:(BOOL)retry {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:retry?@"请检查压缩包密码":@"压缩包需要密码" message:@"支持的加密格式将在本机使用此密码解压；密码不会保存。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.secureTextEntry=YES;field.placeholder=@"压缩包密码";}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){self.importInProgress=NO;[self cleanupArchive];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"解压" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *password=alert.textFields.firstObject.text?:@"";[self afterImportPresentation:^{[self expandArchiveWithPassword:password];}];}]];
    [[self importHost] presentViewController:alert animated:YES completion:nil];
}
- (void)importArchiveProject:(NSDictionary *)project {
    NSString *name=project[@"name"];
    if([project[@"relative"] isEqual:@"压缩包根目录"]){name=self.archiveInputPath.lastPathComponent.stringByDeletingPathExtension;for(NSString *suffix in @[@"tar",@"tgz",@"tbz2",@"txz"])if([name.pathExtension.lowercaseString isEqual:suffix])name=name.stringByDeletingPathExtension;}
    self.archiveProjectName=name;
    [self showArchiveHUD];self.archiveHUD.label.text=@"正在导入工程…";self.archiveHUD.button.hidden=YES;
    self.importInProgress=NO;
    [self importURLs:@[[NSURL fileURLWithPath:project[@"root"] isDirectory:YES]]];
}
- (void)importURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count){[self showImportMessage:@"没有选中的文件或目录。"];return;}
    if(self.importInProgress)return;
    self.importInProgress=YES;
    NSString *projectName=self.archiveProjectName?:urls.firstObject.lastPathComponent.stringByDeletingPathExtension;
    NSMutableArray<NSURL *> *scoped=[NSMutableArray new];
    for(NSURL *url in urls){BOOL granted=[url startAccessingSecurityScopedResource];if(granted)[scoped addObject:url];}
    self.console.text = @"正在复制工程文件…";
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dest = [documents stringByAppendingPathComponent:[@"Imported-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        __block NSError *copyError = nil;
        for (NSURL *url in urls) {
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            NSError *coordinationError = nil;
            [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordinationError byAccessor:^(NSURL *readURL) {
                BOOL directory = NO;
                [NSFileManager.defaultManager fileExistsAtPath:readURL.path isDirectory:&directory];
                if(directory&&urls.count!=1){copyError=[NSError errorWithDomain:@"WorkbenchImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"工程文件夹每次仅支持一个；源码文件支持多选。"}];return;}
                if (directory && urls.count == 1) [NSFileManager.defaultManager copyItemAtPath:readURL.path toPath:dest error:&copyError];
                else {
                    if (![NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&copyError]) return;
                    [NSFileManager.defaultManager copyItemAtPath:readURL.path toPath:[dest stringByAppendingPathComponent:readURL.lastPathComponent] error:&copyError];
                }
            }];
            if (coordinationError) copyError = coordinationError;
            if (copyError) break;
        }
        for(NSURL *url in scoped)[url stopAccessingSecurityScopedResource];
        if(!copyError){for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dest error:nil])if([entry hasPrefix:@".studio-"])[NSFileManager.defaultManager removeItemAtPath:[dest stringByAppendingPathComponent:entry] error:&copyError];}
        if(!copyError)TMCPrepareImportedProject(dest,projectName,&copyError);
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dest error:nil];
        NSMutableArray *sources = [NSMutableArray array];
        NSMutableArray *plists = [NSMutableArray array];
        for (NSString *file in files) {
            if ([@[@"x", @"xm", @"m", @"mm", @"c", @"cpp"] containsObject:file.pathExtension.lowercaseString]) [sources addObject:file];
            if ([file.pathExtension.lowercaseString isEqualToString:@"plist"]) [plists addObject:file];
        }
        NSArray *configuredSources = sourcePaths(dest);
        NSDictionary *config = projectConfig(dest);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.importInProgress=NO;
            [self cleanupArchive];
            self.navigationItem.leftBarButtonItem.enabled = YES;
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (copyError) { [NSFileManager.defaultManager removeItemAtPath:dest error:nil];[self showImportMessage:[@"导入出错：" stringByAppendingString:copyError.localizedDescription]]; return; }
            NSUInteger logosCount = 0;
            for (NSString *name in sources) if ([name.pathExtension.lowercaseString isEqualToString:@"xm"]) logosCount++;
            if (!configuredSources.count) { [NSFileManager.defaultManager removeItemAtPath:dest error:nil];[self showImportMessage:@"没有找到可编译的源码，请检查 MobileCompiler.json 中的 sources 配置。"]; return; }
            [sources sortUsingSelector:@selector(compare:)];
            self.importedSource = configuredSources.firstObject;
            self.importedProject = dest;
            [NSUserDefaults.standardUserDefaults setObject:dest.lastPathComponent forKey:@"ImportedProject"];
            [NSUserDefaults.standardUserDefaults setObject:[self.importedSource substringFromIndex:documents.length + 1] forKey:@"ImportedSourceRelativePath"];
            BOOL control = [files containsObject:@"control"];
            NSString *metadata = (control && plists.count == 1) ? @"将使用导入的 control 和过滤 plist。" : @"未同时提供 control 与过滤 plist，运行时将提示补齐；仅源码测试可使用默认测试元数据。";
            [self showImportMessage:[NSString stringWithFormat:@"已导入 %lu 个源码：%@\n%@\n%@", (unsigned long)configuredSources.count, [config[@"name"] isKindOfClass:NSString.class] ? config[@"name"] : [sources componentsJoinedByString:@", "], metadata, self.hasBuilt ? @"已有构建正在执行。" : @"点击运行开始本机构建。"]];
            if(self.importCompletion){self.pendingImportedProject=dest;[self finishPendingImport];}
            if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-test-project"]) [self runProof];
        });
    });
}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];[self presentPendingPicker];[self finishPendingImport];}
- (void)finishPendingImport{
    if(!self.pendingImportedProject)return;
    UIViewController *host=[self importHost];
    id<UIViewControllerTransitionCoordinator> transition=host.presentedViewController.transitionCoordinator?:host.transitionCoordinator;
    if(transition&&[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){dispatch_async(dispatch_get_main_queue(),^{[self finishPendingImport];});}])return;
    if(host.presentedViewController){
        [host dismissViewControllerAnimated:YES completion:^{[self finishPendingImport];}];
        return;
    }
    NSString *path=self.pendingImportedProject;self.pendingImportedProject=nil;
    if(self.importCompletion)self.importCompletion(path);
}
- (void)exportResult {
    NSMutableArray *files = [NSMutableArray array];
    NSMutableArray *exportNames=[@[@"build.log",@"report.json",@"symbols.json",@"provenance.json",@"checkpoint.json",@"Tweak.mm",@"control",@"filter.plist"] mutableCopy];
    for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.lastBuild error:nil])if([file hasPrefix:@"logos-"]&&[@[@"m",@"mm"] containsObject:file.pathExtension])[exportNames addObject:file];
    id exportReport=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self.lastBuild stringByAppendingPathComponent:@"report.json"]]?:[NSData data] options:0 error:nil];
    if([exportReport isKindOfClass:NSDictionary.class]&&[exportReport[@"namedArtifacts"] isKindOfClass:NSArray.class])[exportNames addObjectsFromArray:exportReport[@"namedArtifacts"]];else [exportNames addObjectsFromArray:@[@"MobileTweak.deb",@"Smoke.dylib"]];
    for(NSDictionary *entry in exportReport[@"symbolProcessing"])if([entry[@"debugFile"] isKindOfClass:NSString.class])[exportNames addObject:entry[@"debugFile"]];
    for (NSString *name in exportNames) {
        NSString *path = [self.lastBuild stringByAppendingPathComponent:name];
        if (path && [NSFileManager.defaultManager fileExistsAtPath:path]) [files addObject:[NSURL fileURLWithPath:path]];
    }
    if (files.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无可导出文件" message:@"请先点击运行。构建完成后，这里会打开系统分享菜单，可保存结果或日志到“文件”。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
    sheet.popoverPresentationController.barButtonItem = self.toolbarItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)runProof {
    if (TMCBuildRunning) { self.console.text = @"已有构建正在执行，请等待当前任务完成。"; return; }
    NSString *projectDirectory = self.importedProject;
    if (!projectDirectory.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:[projectDirectory stringByAppendingPathComponent:@"Makefile"]]) {
        self.console.text = @"请先打开一个 Theos 工程（含 Makefile）。\n本版使用内置工具链（Theos / make）构建，不再提供进程内编译。";
        return;
    }
    if (![SPToolchainInstaller shared].isInstalled) {
        self.console.text = @"内置工具链未就绪：请到「设置 → 工具链」检查安装状态。";
        return;
    }
    self.cancelRequested = NO; TMCBuildRunning = YES; self.hasBuilt = YES; self.lastPackage = nil;
    TFScreenAwakeSet(@"build", YES);
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    ((UIBarButtonItem *)self.toolbarItems.firstObject).enabled = NO;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.lastBuild = [documents stringByAppendingPathComponent:[@"Build-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *build = self.lastBuild;
    self.console.text = @"使用内置工具链（Theos / make）构建…\n";
    NSTimeInterval startedAt = NSDate.date.timeIntervalSince1970;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) self = weakSelf; if (!self) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:build withIntermediateDirectories:YES attributes:nil error:NULL];
        BOOL ok = [self tryTheosBuildProject:projectDirectory buildDir:build];
        NSMutableArray *artifacts = [NSMutableArray array];
        if (ok) {
            NSString *packages = [projectDirectory stringByAppendingPathComponent:@"packages"];
            for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:packages error:NULL] ?: @[]) {
                if (![@[@"deb", @"dylib", @"tipa"] containsObject:name.pathExtension.lowercaseString]) continue;
                NSString *source = [packages stringByAppendingPathComponent:name];
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:source error:NULL];
                if ([attrs[NSFileModificationDate] timeIntervalSince1970] < startedAt - 1) continue;
                NSString *dest = [build stringByAppendingPathComponent:name];
                [[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];
                if ([[NSFileManager defaultManager] copyItemAtPath:source toPath:dest error:NULL]) [artifacts addObject:name];
            }
        }
        NSDictionary *report = @{@"success": @(ok), @"engine": @"theos-make",
                                 @"startedAt": @(startedAt), @"finishedAt": @(NSDate.date.timeIntervalSince1970),
                                 @"namedArtifacts": artifacts};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL]
            writeToFile:[build stringByAppendingPathComponent:@"report.json"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastPackage = artifacts.firstObject ? [build stringByAppendingPathComponent:artifacts.firstObject] : nil;
            self.console.text = [(self.console.text ?: @"") stringByAppendingString:
                ok ? @"BUILD SUCCEEDED — 工具链（Theos / make）\n" : @"BUILD FAILED — 工具链（Theos / make）\n"];
            TFScreenAwakeSet(@"build", NO);
            self.navigationItem.rightBarButtonItem.enabled = YES;
            self.navigationItem.leftBarButtonItem.enabled = YES;
            ((UIBarButtonItem *)self.toolbarItems.firstObject).enabled = YES;
            self.hasBuilt = NO; TMCBuildRunning = NO;
            if (self.buildCompletion) self.buildCompletion(ok);
        });
    });
}
@end

#if TARGET_OS_SIMULATOR
#include "../tests/RemoteSimulatorRegression.inc"
#endif
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) BOOL restoringData;
@property(nonatomic) NSURL *pendingRestoreURL;
@property(nonatomic) BOOL interfaceStarted;
- (BOOL)startInterfaceWithOptions:(NSDictionary *)options;
@end

// UIKit owns the window lifecycle; retain the same window during data restoration.
@interface WorkbenchSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation WorkbenchSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    AppDelegate *app = (AppDelegate *)UIApplication.sharedApplication.delegate;
    if (!app.window) app.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    else app.window.windowScene = (UIWindowScene *)scene;
    self.window = app.window;
    [app startInterfaceWithOptions:@{}];
    for (UIOpenURLContext *context in options.URLContexts)
        [app application:UIApplication.sharedApplication openURL:context.URL options:@{}];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    AppDelegate *app = (AppDelegate *)UIApplication.sharedApplication.delegate;
    for (UIOpenURLContext *context in contexts)
        [app application:UIApplication.sharedApplication openURL:context.URL options:@{}];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    AppDelegate *app = (AppDelegate *)UIApplication.sharedApplication.delegate;
    [app applicationDidBecomeActive:UIApplication.sharedApplication];
}
@end
@implementation AppDelegate
- (void)openBuildQueueFromNotification:(NSNotification *)note{UIViewController *root=self.window.rootViewController;if(root.presentedViewController)return;if([root isKindOfClass:UITabBarController.class])root=[(UITabBarController *)root selectedViewController];if([root isKindOfClass:UINavigationController.class])[(UINavigationController *)root pushViewController:TFAIBuildQueueController() animated:YES];}
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {if(self.restoringData){self.pendingRestoreURL=url;return YES;}if(url.isFileURL){TFIncomingReceive(self.window.rootViewController,url);return YES;}if(([url.scheme isEqual:@"workbench"]||[url.scheme isEqual:@"workbench"])&&[url.host isEqual:@"incoming"]){TFIncomingDrain(self.window.rootViewController);return YES;}return NO;}
- (void)applicationDidBecomeActive:(UIApplication *)application {if(!self.restoringData)TFIncomingDrain(self.window.rootViewController);}
// 启动时核对关键资源，缺什么写进 startup.log（不是崩溃原因也留证据）。
static void TMCBundleAudit(void) {
    NSString *bundle = [NSBundle.mainBundle bundlePath];
    NSArray *required = @[@"RemoteWeb/index.html", @"FLEXPlugin/manifest.json",
                          @"iSH/alpine-minirootfs-3.21.0-aarch64.tar.gz",
                          @"Toolchain/theos-root/usr/bin/clang-16",
                          @"Toolchain/theos-root/usr/bin/ldid",
                          @"Toolchain/reverse/bin/r2",
                          @"bin/spark-jitd"];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *relative in required) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[bundle stringByAppendingPathComponent:relative]]) {
            [missing addObject:relative];
        }
    }
    TMCMarkStartup(missing.count ? [@"缺少资源: " stringByAppendingString:[missing componentsJoinedByString:@", "]]
                                 : @"资源自检通过");
}

// 启动断点：每次里程碑写一行到 Documents/Workbench-startup.log。
// 闪退后用户可以从「文件」里把这个日志发出来，直接定位崩在哪一步。
static void TMCMarkStartup(NSString *stage) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    NSString *path = [documents stringByAppendingPathComponent:@"Workbench-startup.log"];
    NSString *line = [NSString stringWithFormat:@"%.3f %@ (uid=%d)\n",
                      NSDate.date.timeIntervalSince1970, stage, (int)getuid()];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) { [handle seekToEndOfFile]; [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [handle closeFile]; }
    else { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    [WBCrashGuard install];
    // BGTask handlers must be registered before this method returns, before scene connection.
    TFAIBackgroundRegister();
    return YES;
}
- (BOOL)startInterfaceWithOptions:(NSDictionary *)options {
    if (self.interfaceStarted) return YES;
    self.interfaceStarted = YES;
    NSString *pending=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WorkbenchRestore/pending.json"];
    if(![NSFileManager.defaultManager fileExistsAtPath:pending])return [self finishLaunching:options];
    self.restoringData=YES;
    // Return to UIKit immediately: large restores must not trigger the launch watchdog.
    if (!self.window.windowScene) {
        TMCMarkStartup(@"windowScene 缺失");
        self.window = self.window; // 保留对象，后续 UIKit 会在可用时补上
    } else {
        TMCMarkStartup(@"windowScene 就绪");
    }
    UIViewController *loading=[UIViewController new];loading.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[UILabel new];label.text=@"正在恢复 Workbench 数据，请勿关闭应用";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];label.translatesAutoresizingMaskIntoConstraints=NO;
    UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];spinner.translatesAutoresizingMaskIntoConstraints=NO;[spinner startAnimating];
    [loading.view addSubview:label];[loading.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[[label.centerXAnchor constraintEqualToAnchor:loading.view.centerXAnchor],[label.centerYAnchor constraintEqualToAnchor:loading.view.centerYAnchor],[spinner.centerXAnchor constraintEqualToAnchor:loading.view.centerXAnchor],[spinner.bottomAnchor constraintEqualToAnchor:label.topAnchor constant:-20]]];
    self.window.rootViewController=loading;[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *error=nil;DXBackupApplyPending(NSHomeDirectory(),&error);dispatch_async(dispatch_get_main_queue(),^{self.restoringData=NO;NSMutableDictionary *launch=[options mutableCopy]?:[NSMutableDictionary new];if(self.pendingRestoreURL)launch[UIApplicationLaunchOptionsURLKey]=self.pendingRestoreURL;self.pendingRestoreURL=nil;[self finishLaunching:launch];if(error){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"数据恢复未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];[self.window.rootViewController presentViewController:alert animated:YES completion:nil];}});});
    return YES;
}
- (BOOL)finishLaunching:(NSDictionary *)options {
    TMCMarkStartup(@"finishLaunching 开始");
    TMCBundleAudit();
    [DXRemoteService shared];
    TFAINotificationsRegister();[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(openBuildQueueFromNotification:) name:@"TFAIOpenBuildQueue" object:nil];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"StudioTheme":@1, @"StudioFont":@14, @"StudioSDKVersion":@"16.5", @"StudioDeploymentTarget":@"15.0"}];
    if (!self.window.windowScene) {
        TMCMarkStartup(@"windowScene 缺失");
        self.window = self.window; // 保留对象，后续 UIKit 会在可用时补上
    } else {
        TMCMarkStartup(@"windowScene 就绪");
    }
    self.window.tintColor=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait){return trait.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:.93 green:.77 blue:.52 alpha:1]:[UIColor colorWithRed:.45 green:.30 blue:.10 alpha:1];}];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{TMCPrepareDocumentPresentation(documents);});
    for(NSString *name in @[@"import.log",@"picker-test.json"])[NSFileManager.defaultManager removeItemAtPath:[documents stringByAppendingPathComponent:name] error:nil];
    // Only unreported builds from earlier processes are marked interrupted.
    for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:documents error:nil])if([entry hasPrefix:@"Build-"]){NSString *path=[documents stringByAppendingPathComponent:entry],*marker=[path stringByAppendingPathComponent:@".build-in-progress.json"],*report=[path stringByAppendingPathComponent:@"report.json"];if([NSFileManager.defaultManager fileExistsAtPath:marker]&&![NSFileManager.defaultManager fileExistsAtPath:report]){NSDictionary *interrupted=@{@"success":@NO,@"commands":@[],@"interrupted":@YES,@"packageError":@"上次构建被系统或应用退出中断，请重新构建。原始日志已保留。"};[[NSJSONSerialization dataWithJSONObject:interrupted options:0 error:nil] writeToFile:report atomically:YES];}}
    BOOL testing = [NSProcessInfo.processInfo.arguments containsObject:@"--self-test"] || [NSProcessInfo.processInfo.arguments containsObject:@"--self-test-project"];
    TMCMarkStartup(@"准备 rootViewController");
    self.window.rootViewController = testing ? [[TMCNavigationController alloc] initWithRootViewController:[CompilerController new]] : TMCStudioRoot();
    TMCMarkStartup(@"rootViewController 已设置");
#if TARGET_OS_SIMULATOR
#if WORKBENCH_HAS_INTEGRATION165
    extern UIViewController *DXIntegration165Controller(void);
    if([NSProcessInfo.processInfo.arguments containsObject:@"--integration165-tests"])self.window.rootViewController=[[TMCNavigationController alloc]initWithRootViewController:DXIntegration165Controller()];
#endif
    if([NSProcessInfo.processInfo.arguments containsObject:@"--session239"]){extern UIViewController *TMCSessionArchive239Regression(void);self.window.rootViewController=TMCSessionArchive239Regression();}
    if([NSProcessInfo.processInfo.arguments containsObject:@"--data-settings237"]){extern UIViewController *TMCData237SettingsRegression(void);self.window.rootViewController=TMCData237SettingsRegression();}
    if([NSProcessInfo.processInfo.arguments containsObject:@"--ui235-tests"]){extern UIViewController *TMCChatNavigation235Regression(void);self.window.rootViewController=TMCChatNavigation235Regression();}
    if([NSProcessInfo.processInfo.arguments containsObject:@"--maintenance-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCMaintenanceRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--storage258-test"])
        self.window.rootViewController=TMCStorageBackup258Regression();
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--storage-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStorageController()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--settings-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioSettingsRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--git-automation-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCGitAutomationRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--file-actions-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioFileActionsRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--git-ui-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCGitRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--about-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioAboutRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--repair-sheet-test"]||[NSProcessInfo.processInfo.arguments containsObject:@"--repair-confirm-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioRepairRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--project-settings-sheet-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioProjectSettingsRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--diagnostic-jump-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioDiagnosticJumpRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--sdk118-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioSDKRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--build-preferences-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioBuildPreferencesRegression()];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--editor-layout-test"])
        self.window.rootViewController=[[TMCNavigationController alloc] initWithRootViewController:TMCStudioEditorRegression()];
#endif
    [self.window makeKeyAndVisible];
    DXAppUpdateOnLaunch(self.window.rootViewController);
    NSURL *incoming=options[UIApplicationLaunchOptionsURLKey];if(incoming)dispatch_async(dispatch_get_main_queue(),^{TFIncomingReceive(self.window.rootViewController,incoming);});
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}

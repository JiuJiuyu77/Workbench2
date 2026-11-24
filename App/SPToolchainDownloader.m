//
//  SPToolchainDownloader.m  (重写：改为由 ProjectKit/src/runtimes.mjs 的数据驱动)
//

#import "SPToolchainDownloader.h"
#import "SPRuntimeManifestFallback.h"
#import "SPToolchain.h"
#import "SPToolchainInstaller.h"
#import "SPSession.h"
#import "SPCompat.h"
#import "SPNetworkMonitor.h"

static NSString *const kComponentStateKey = @"Workbench.downloadedComponents";

/**
 * 运行时清单 —— 唯一真相是 Native/Resources/runtime-manifest.json。
 *
 * 优先级：
 *   1. bundle 里的 runtime-manifest.json（构建时拷进 .app，改数据不用重编译）
 *   2. 编译进二进制的兜底（SPRuntimeManifestFallback.h，由同一份 JSON 自动生成）
 *
 * 为什么这样做：以前 ObjC 与 ProjectKit/src/runtimes.mjs 各写一份，
 * 体积 / 探测命令 / 解包路径长期不一致（例如 theos 标 114MB 实际 259MB、
 * coretools 标 40MB 实际 9.9MB、python 的 bin/python3 实际在包顶层）。
 * 现在数据只有一份，两端都从这里读。
 */
static NSArray<NSDictionary *> *SPRuntimeManifest(void) {
    static NSArray *m;
    static dispatch_once_t manifestOnce;
    dispatch_once(&manifestOnce, ^{
        NSArray *loaded = nil;

        // 1) bundle 里的 JSON
        NSString *path = [[NSBundle mainBundle] pathForResource:@"runtime-manifest" ofType:@"json"];
        if (!path.length) {
            // 兼容：某些构建把资源放在 .app 根目录但没有 bundle 索引
            path = [[[NSBundle mainBundle] bundlePath]
                    stringByAppendingPathComponent:@"runtime-manifest.json"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = nil;
        }
        if (path.length) {
            NSData *d = [NSData dataWithContentsOfFile:path];
            if (d) {
                id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
                if ([j isKindOfClass:NSDictionary.class]) {
                    id comps = ((NSDictionary *)j)[@"components"];
                    if ([comps isKindOfClass:NSArray.class] && [comps count]) {
                        loaded = comps;
                    }
                }
            }
        }

        // 2) 兜底（与 JSON 同源生成）
        m = loaded ?: SPRuntimeManifestFallback();
        SPLog(@"运行时清单：%lu 个组件（来源：%@）",
              (unsigned long)m.count, loaded ? @"bundle JSON" : @"内置兜底");
    });
    return m;
}

/// 直连失败时用的镜像前缀（与 runtime-manifest.json 的 proxyPrefixes 同源）
static NSArray<NSString *> *SPProxyPrefixes(void) {
    static NSArray *list;
    static dispatch_once_t proxyOnce;
    dispatch_once(&proxyOnce, ^{
        NSMutableArray *out = [NSMutableArray arrayWithObject:@""];   // 先直连
        NSString *path = [[NSBundle mainBundle] pathForResource:@"runtime-manifest" ofType:@"json"];
        NSData *d = path.length ? [NSData dataWithContentsOfFile:path] : nil;
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        id pfx = [j isKindOfClass:NSDictionary.class] ? ((NSDictionary *)j)[@"proxyPrefixes"] : nil;
        if ([pfx isKindOfClass:NSArray.class]) {
            for (id p in pfx) if ([p isKindOfClass:NSString.class]) [out addObject:p];
        }
        if (out.count == 1) {   // 兜底
            [out addObject:@"https://gh-proxy.org/"];
            [out addObject:@"https://ghproxy.net/"];
        }
        list = [out copy];
    });
    return list;
}

@implementation SPComponentInfo
- (BOOL)isInstalled {
    SPComponent c = self.component;
    // SDK 组件：判断目标 SDK 是否真实存在（走 SPToolchain 的完整性判定，
    // 不依赖 .installed 标记——SDK 包解到 installRoot 顶层，不能污染它的展开状态）。
    if (c == SPComponentSDK17 || c == SPComponentSDK26) {
        NSString *ver = (c == SPComponentSDK17) ? @"17.0" : @"26.5";
        NSString *name = [NSString stringWithFormat:@"iPhoneOS%@.sdk", ver];
        return [[[SPToolchain shared] availableSDKs] containsObject:name];
    }
    NSString *dir = [[SPToolchainDownloader shared] directoryFor:self.component];
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [dir stringByAppendingPathComponent:@".installed"]];
}
@end

@interface SPToolchainDownloader () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, copy) void (^progressBlock)(CGFloat, NSString *);
@property (nonatomic, copy) void (^completionBlock)(BOOL, NSError *);
@property (nonatomic, assign) SPComponent currentComponent;
/// 因网络不可用而挂起的组件编号；-1 表示没有挂起项（0 是合法编号）
@property (nonatomic, assign) NSInteger pendingComponent;
@property (nonatomic, strong) NSString *destinationDir;
@property (nonatomic, assign) NSInteger proxyIndex;
@end

@implementation SPToolchainDownloader

+ (instancetype)shared {
    static SPToolchainDownloader *d; static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [SPToolchainDownloader new];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 7200;
        d.session = [NSURLSession sessionWithConfiguration:cfg delegate:d delegateQueue:nil];
        d.pendingComponent = -1;   // -1 = 没有挂起的组件（0 是合法的组件编号，不能用来表示空）
        [[NSNotificationCenter defaultCenter] addObserver:d
                                                 selector:@selector(networkRestored:)
                                                     name:SPNetworkRestoredNotification
                                                   object:nil];
        [[SPNetworkMonitor shared] start];
    });
    return d;
}

/// 组件 → 安装子目录（与 runtimes.mjs 的 id 对齐）
- (NSString *)directoryFor:(SPComponent)component {
    NSArray *m = SPRuntimeManifest();
    NSString *root = [SPToolchainInstaller shared].installRoot;
    // SDK 组件：归档内部自带 sdks/ 前缀，直接解到 installRoot 顶层
    //（installRoot/sdks/iPhoneOS17.0.sdk/...），不能嵌套成 installRoot/sdk17。
    if (component == SPComponentSDK17 || component == SPComponentSDK26) {
        return root;
    }

    if (component >= 0 && component < (NSInteger)m.count) {
        return [root stringByAppendingPathComponent:m[component][@"id"]];
    }
    return root;
}

- (NSArray<SPComponentInfo *> *)components {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *m = SPRuntimeManifest();
    for (NSInteger i = 0; i < (NSInteger)m.count; i++) {
        NSDictionary *d = m[i];
        SPComponentInfo *c = [SPComponentInfo new];
        c.component = i;
        c.title = d[@"name"];
        c.detail = d[@"detail"];
        c.symbol = d[@"symbol"];
        c.approxSize = [d[@"size"] unsignedLongLongValue];
        [out addObject:c];
    }
    return out;
}

- (void)reload { /* 状态懒判断 */ }

#pragma mark - 下载

- (void)startTaskForCurrentComponent {
    NSArray *m = SPRuntimeManifest();
    NSInteger i = self.currentComponent;
    if (i < 0 || i >= (NSInteger)m.count) {
        if (self.completionBlock) self.completionBlock(NO, SPError(SPErrorCodeIO, @"未知组件"));
        return;
    }
    NSString *url = m[i][@"archive"];
    NSArray *prefixes = SPProxyPrefixes();
    if (self.proxyIndex >= (NSInteger)prefixes.count) {
        if (self.completionBlock) self.completionBlock(NO, SPError(SPErrorCodeIO, @"所有下载源都失败，请检查网络"));
        self.task = nil;
        return;
    }
    NSString *prefix = prefixes[self.proxyIndex];
    NSString *finalURL = [prefix stringByAppendingString:url];
    if (self.progressBlock) {
        NSString *via = prefix.length ? [NSString stringWithFormat:@"（镜像 %@）", prefix] : @"（直连）";
        self.progressBlock(0.02, [NSString stringWithFormat:@"连接中%@", via]);
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:finalURL]];
    [req setValue:@"Workbench/1.3" forHTTPHeaderField:@"User-Agent"];
    self.task = [self.session downloadTaskWithRequest:req];
    [self.task resume];
}

- (void)download:(SPComponent)component
        progress:(void (^)(CGFloat, NSString *))progress
      completion:(void (^)(BOOL, NSError *))completion {
    if (self.task) {
        if (completion) completion(NO, SPError(SPErrorCodeIO, @"已有下载在进行"));
        return;
    }
    self.currentComponent = component;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.destinationDir = [self directoryFor:component];
    self.proxyIndex = 0;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.destinationDir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [self startTaskForCurrentComponent];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.destinationDir;

    // 用内置 tar 解包（core_tools 没装时退回系统 tar）
    NSString *tar = [SPUtil findExecutable:@[@"tar"] searchDirs:@[
        [SPToolchainInstaller shared].binDir,
        [SPToolchainInstaller shared].installRoot,
        @"/usr/bin", @"/var/jb/usr/bin", @"/bin"]];
    BOOL ok = NO;
    BOOL isSDK = (self.currentComponent == SPComponentSDK17 || self.currentComponent == SPComponentSDK26);
    if (tar) {
        if (self.progressBlock) dispatch_async(dispatch_get_main_queue(), ^{ self.progressBlock(0.95, @"解包…"); });
        NSString *cmd = [NSString stringWithFormat:
            @"%@ xzf %@ -C %@ 2>/dev/null || %@ xzf %@ -C %@ --strip-components=1 2>/dev/null",
            [SPUtil shellQuote:tar], [SPUtil shellQuote:location.path], [SPUtil shellQuote:dir],
            [SPUtil shellQuote:tar], [SPUtil shellQuote:location.path], [SPUtil shellQuote:dir]];
        SPCommandResult *r = [SPSession runSyncShell:cmd environment:@{} cwd:NSTemporaryDirectory() timeout:600];
        ok = (r.exitCode == 0);
    }
    if (ok) {
        // SDK 组件解到 installRoot 顶层，不能写 .installed（会污染全局安装状态），
        // 也不需要给 bin/sbin/libexec 补执行位。
        if (!isSDK) {
            // 补执行权限
            for (NSString *sub in @[@"bin", @"sbin", @"libexec"]) {
                NSString *d = [dir stringByAppendingPathComponent:sub];
                for (NSString *f in [fm contentsOfDirectoryAtPath:d error:NULL] ?: @[]) {
                    [fm setAttributes:@{NSFilePosixPermissions: @(0755)}
                   ofItemAtPath:[d stringByAppendingPathComponent:f] error:NULL];
                }
            }
            [@"ok" writeToFile:[dir stringByAppendingPathComponent:@".installed"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock(1.0, ok ? @"完成" : @"解包失败");
        if (self.completionBlock) self.completionBlock(ok, ok ? nil : SPError(SPErrorCodeIO, @"解包失败"));
        self.task = nil;
        self.progressBlock = nil;
        self.completionBlock = nil;
        [[SPToolchain shared] rescan];
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite <= 0) return;
    CGFloat f = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
    NSString *text = [NSString stringWithFormat:@"%@ / %@",
                      [SPUtil formatBytes:(unsigned long long)totalBytesWritten],
                      [SPUtil formatBytes:(unsigned long long)totalBytesExpectedToWrite]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBlock) self.progressBlock(MAX(0.02, f * 0.93), text);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    // 直连失败 → 换镜像重试
    dispatch_async(dispatch_get_main_queue(), ^{
        self.proxyIndex += 1;
        self.task = nil;
        if (self.proxyIndex < (NSInteger)SPProxyPrefixes().count) {
            [self startTaskForCurrentComponent];
            return;
        }

        // 所有镜像都失败。区分「网络问题」和「资源真没了」：
        // 网络类错误（断网 / 超时 / 连接被拒）→ 挂起，等网络恢复自动重排，
        // 不要立刻报失败让用户手动重来（大文件下载到 90% 断掉重来代价太高）。
        BOOL networkError = [self isNetworkError:error];
        if (networkError && ![[SPNetworkMonitor shared] isNetworkAvailable]) {
            SPLog(@"下载因网络不可用挂起，等网络恢复后自动重试（组件 %ld）",
                  (long)self.currentComponent);
            self.pendingComponent = self.currentComponent;
            if (self.progressBlock) {
                self.progressBlock(0.0, @"网络不可用 —— 已挂起，联网后自动继续");
            }
            // 注意：这里**不**调用 completionBlock，也不清空它，
            // 保留调用方的回调，等重试成功/彻底失败再回调。
            return;
        }

        if (self.completionBlock) self.completionBlock(NO, error);
        self.progressBlock = nil;
        self.completionBlock = nil;
    });
}

/// 判断是否是「可以等网络恢复」的错误
- (BOOL)isNetworkError:(NSError *)error {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorTimedOut:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorDataNotAllowed:
        case NSURLErrorInternationalRoamingOff:
            return YES;
        default:
            return NO;
    }
}

/// 网络恢复：把挂起的组件从「直连」开始重排一遍
- (void)networkRestored:(NSNotification *)note {
    if (self.pendingComponent < 0) return;
    SPComponent comp = (SPComponent)self.pendingComponent;
    self.pendingComponent = -1;
    // 必须把 currentComponent 一起改回来：startTaskForCurrentComponent
    // 读的是 currentComponent，不改就会去重下「上一次失败的另一个组件」。
    self.currentComponent = comp;
    self.proxyIndex = 0;
    SPLog(@"网络已恢复，重新开始下载组件 %ld", (long)comp);
    [self startTaskForCurrentComponent];
}

- (void)remove:(SPComponent)component {
    [[NSFileManager defaultManager] removeItemAtPath:[self directoryFor:component] error:NULL];
    [[SPToolchain shared] rescan];
}

@end

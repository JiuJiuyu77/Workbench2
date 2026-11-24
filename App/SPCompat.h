//
//  SPCompat.h
//  Workbench —— 共享在 ShareKit / ProjectKit / App 三处的基础宏与轻量封装。
//
//  原则：不依赖任何第三方库（Rein 环境里没有 Cephei 的保证），
//  只用 Foundation + UIKit，能在 iOS 15~17 上编译，也能在 macOS 上用
//  Xcode 的 iOS 模拟器 SDK 做「语法与类型检查」。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志：除了系统日志，同时写入内存环形缓冲 + 文件。
///
/// 为什么必须改：
///  之前 SPLog 只调 NSLog，内容只进系统日志（Console.app 才能看）。
///  App 内的日志页面完全看不到这些 —— 用户看到的就是「日志不完整」，
///  而真正的错误信息（setuid 失败、shell 找不到、着色器缺失）全在里面。
#define SPLog(fmt, ...) do { \
    NSString *_msg = [NSString stringWithFormat:(@"[Workbench] " fmt), ##__VA_ARGS__]; \
    NSLog(@"%@", _msg); \
    SPAppendLog(_msg); \
} while (0)

/// 供 SPLog 使用：追加到内存缓冲并落盘（线程安全，可重入）
FOUNDATION_EXPORT void SPAppendLog(NSString *message);
/// 取最近 N 条日志（日志页面用）
FOUNDATION_EXPORT NSArray<NSString *> *SPRecentLogs(NSUInteger limit);
/// 日志文件路径（「分享日志」用）
FOUNDATION_EXPORT NSString *SPLogFilePath(void);

/// 只在 DEBUG 下输出
#ifdef DEBUG
#  define SPDebug(fmt, ...) SPLog(fmt, ##__VA_ARGS__)
#else
#  define SPDebug(fmt, ...) do {} while (0)
#endif

/// 数组安全取值：越界会抛 NSRangeException，
/// 而这类代码常在 cellForRow 里（主线程 UI 路径），一抛就是 abort。
///
/// 用**函数**而不是宏：宏的参数里只要出现逗号（数组字面量必然有）
/// 就会被当成多个参数，编译报 "too many arguments to macro"。
FOUNDATION_EXPORT id SPAtIndex(NSArray *array, NSInteger index, id fallback);

/// 安全的对象取值（避免 valueForKey 抛 NSException）
static inline id SPOrNil(id _Nullable a, id fallback) { return a ?: fallback; }

/// NSString 安全转换
static inline NSString *SPStr(NSString *_Nullable s) { return s ?: @""; }

#pragma mark - 版本

@interface SPVersion : NSObject

/// 形如 "1.0.0"
@property (nonatomic, copy, readonly) NSString *semver;
/// git describe 结果（由 CI 注入）
@property (nonatomic, copy, readonly) NSString *gitDescribe;
/// 构建时间字符串
@property (nonatomic, copy, readonly) NSString *builtAt;

+ (instancetype)shared;
@end

#pragma mark - 通用工具

@interface SPUtil : NSObject

/// 把秒数格式化成 "01:23" / "1:02:03"
+ (NSString *)formatDuration:(NSTimeInterval)seconds;

/// 人类可读的文件大小
+ (NSString *)formatBytes:(unsigned long long)bytes;

/// 以 shell 安全的方式为单个参数加单引号
+ (NSString *)shellQuote:(NSString *)s;

/// 把字典写成 env 风格 "K=V" 数组（值中不会出现换行）
+ (NSArray<NSString *> *)envPairsFromDictionary:(NSDictionary<NSString *, NSString *> *)dict;

/// 读取 plist 里的字符串值，缺失时返回 default
+ (NSString *)stringFromPlistAtPath:(NSString *)path key:(NSString *)key default:(NSString *)def;

/// 生成时间戳文件名后缀，例如 20261115-091500
+ (NSString *)timestampSlug;

/// 递归复制目录（覆盖），返回失败时的错误
+ (nullable NSError *)copyDirectory:(NSString *)src to:(NSString *)dst;

/// 删除路径（不存在不报错）
+ (void)removeItemIfExists:(NSString *)path;

/// 确保目录存在
+ (BOOL)ensureDirectory:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

/// 查找可执行文件：先看 preferred 列表，再按 PATH 里找；
/// searchDirs 可以为 nil（默认只查 preferred）。
+ (nullable NSString *)findExecutable:(NSArray<NSString *> *)names
                           searchDirs:(nullable NSArray<NSString *> *)dirs;

@end

/// 常用 NSError domain
extern NSString *const SPErrorDomain;

typedef NS_ENUM(NSInteger, SPErrorCode) {
    SPErrorCodeCancelled = 1,
    SPErrorCodeMissingToolchain,
    SPErrorCodeInvalidProject,
    SPErrorCodeLaunchFailed,
    SPErrorCodeNonZeroExit,
    SPErrorCodeIO,
    SPErrorCodeUnsupported,
    SPErrorCodeTimeout,
};

static inline NSError *SPError(SPErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:SPErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

NS_ASSUME_NONNULL_END

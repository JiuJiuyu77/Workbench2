//
//  SPModels.h
//  Workbench —— 项目、构建选项、任务、日志的模型层。
//  全部可 JSON 序列化，便于「最近项目」「构建历史」「远程/CI 传输」。
//

#import <Foundation/Foundation.h>
#import "SPToolchain.h"

NS_ASSUME_NONNULL_BEGIN

/// 项目类型（由 Makefile/目录结构探测得出）
typedef NS_ENUM(NSInteger, SPProjectKind) {
    SPProjectKindUnknown = 0,
    SPProjectKindTweak,       // THEOS_PACKAGE_SCHEME / tweak
    SPProjectKindApplication, // application
    SPProjectKindLibrary,     // library
    SPProjectKindTool,        // tool
    SPProjectKindBundle,      // bundle
    SPProjectKindNode,        // package.json
    SPProjectKindScript,      // 只有 build 脚本
};

/// 打包格式
typedef NS_ENUM(NSInteger, SPPackageFormat) {
    SPPackageFormatDeb = 0,      // 有根 rootful
    SPPackageFormatRootlessDeb,  // 无根 rootless
    SPPackageFormatRootHideDeb,  // 隐根 roothide
    SPPackageFormatApp,          // 不打包，直接产出 .app
    SPPackageFormatTIPA,
};

/// 架构
typedef NS_ENUM(NSInteger, SPArch) {
    SPArchArm64 = 0,
    SPArchArm64e,
    SPArchBoth,
};

/// 编译优化等级
typedef NS_ENUM(NSInteger, SPOptimization) {
    SPOptimizationO0 = 0,   // -O0 调试
    SPOptimizationOg,       // -Og 调试友好
    SPOptimizationO1,       // -O1
    SPOptimizationO2,       // -O2 发布推荐
    SPOptimizationO3,       // -O3 激进
    SPOptimizationOs,       // -Os 优化体积
    SPOptimizationOz,       // -Oz 极限体积
    SPOptimizationOfast,    // -Ofast（注意浮点行为）
};

/// OLLVM 混淆等级（对应 Rein 的 passes 组合）
typedef NS_ENUM(NSInteger, SPObfuscation) {
    SPObfuscationNone = 0,
    SPObfuscationLight,     // indbr + cse
    SPObfuscationBalanced,  // indbr + icall + cse
    SPObfuscationStrong,    // 全部 5 个 pass
    SPObfuscationCustom,    // 自定义 passes
};

#pragma mark - 构建选项

@interface SPBuildOptions : NSObject <NSCopying>

@property (nonatomic, assign) SPArch arch;
@property (nonatomic, assign) SPPackageFormat format;
@property (nonatomic, assign) BOOL debug;
/// 优化等级（debug 时自动用 O0）
@property (nonatomic, assign) SPOptimization optimization;
@property (nonatomic, assign) BOOL cleanBeforeBuild;
@property (nonatomic, assign) BOOL finalize;      // 打包并生成 deb
@property (nonatomic, assign) BOOL signWithLdid;
@property (nonatomic, assign) BOOL strip;
@property (nonatomic, assign) BOOL useOLLVM;
@property (nonatomic, assign) SPObfuscation obfuscation;
@property (nonatomic, copy) NSArray<NSString *> *obfuscationPasses; // 自定义时生效
@property (nonatomic, copy, nullable) NSString *packageVersionOverride;
@property (nonatomic, copy, nullable) NSString *extraMakeArgs;      // 原样拼在 make 后面
@property (nonatomic, copy, nullable) NSString *extraEnv;           // "K=V\nK2=V2"
@property (nonatomic, assign) BOOL parallel;                        // -jN
@property (nonatomic, assign) NSInteger jobs;

- (NSArray<NSString *> *)makeArguments;
/// 优化等级名（@"O0" / @"O2" / @"Os" …）
- (NSString *)optimizationName;
- (NSDictionary<NSString *, NSString *> *)makeEnvironment;
- (NSString *)displaySummary;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)optionsFromDictionary:(NSDictionary *)dict;

@end

#pragma mark - 项目

@interface SPProject : NSObject

@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) SPProjectKind kind;
@property (nonatomic, copy, nullable) NSString *packageId;      // com.example.foo
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *executable;     // 主二进制名
@property (nonatomic, copy, nullable) NSString *makefilePath;
@property (nonatomic, copy) NSArray<NSString *> *sourceFiles;   // 相对路径
@property (nonatomic, copy) NSArray<NSString *> *headers;
@property (nonatomic, copy, nullable) NSString *buildDir;       // ".theos"
@property (nonatomic, copy, nullable) NSString *layoutDir;      // "layout"
@property (nonatomic, assign) BOOL isTheosProject;
@property (nonatomic, copy) SPBuildOptions *options;
@property (nonatomic, strong) NSDate *lastOpenedAt;

+ (nullable instancetype)projectAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;
- (void)reload;
- (NSArray<NSString *> *)fileTreeFlattened;   // 供文件浏览使用
- (NSString *)kindString;

@end

#pragma mark - 日志

typedef NS_ENUM(NSInteger, SPLogLevel) {
    SPLogLevelOut = 0,
    SPLogLevelErr,
    SPLogLevelInfo,
    SPLogLevelStep,
};

@interface SPLogLine : NSObject
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) SPLogLevel level;
@property (nonatomic, copy) NSString *text;
+ (instancetype)lineWithText:(NSString *)text level:(SPLogLevel)level;
@end

#pragma mark - 任务

typedef NS_ENUM(NSInteger, SPJobState) {
    SPJobStateQueued = 0,
    SPJobStateRunning,
    SPJobStateSucceeded,
    SPJobStateFailed,
    SPJobStateCancelled,
};

@interface SPJob : NSObject

@property (nonatomic, copy) NSString *jobId;
@property (nonatomic, copy) NSString *projectPath;
@property (nonatomic, copy) NSString *projectName;
@property (nonatomic, strong) SPBuildOptions *options;
@property (nonatomic, assign) SPBuildTarget target;
@property (nonatomic, assign) SPJobState state;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSDate *finishedAt;
@property (nonatomic, assign) NSInteger exitCode;
@property (nonatomic, copy) NSArray<SPLogLine *> *lines;
@property (nonatomic, copy) NSArray<NSString *> *artifacts;       // 产出的文件绝对路径
@property (nonatomic, copy, nullable) NSString *bundlePath;       // .deb 或 .app
@property (nonatomic, copy, nullable) NSString *failureHint;      // 从日志推断的错误说明

- (NSTimeInterval)duration;
- (NSString *)stateString;
- (NSDictionary *)dictionaryRepresentation;

@end

NS_ASSUME_NONNULL_END

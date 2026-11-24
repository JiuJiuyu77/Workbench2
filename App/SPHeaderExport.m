//
//  SPHeaderExport.m
//

#import "SPHeaderExport.h"
#import "SPToolchain.h"
#import "SPToolchainInstaller.h"
#import "SPSession.h"
#import "SPCompat.h"

@implementation SPHeaderExport

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)objcClassesAndMethodsInBinary:(NSString *)binaryPath
                                                                            error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
        if (error) *error = SPError(SPErrorCodeIO, @"文件不存在");
        return @{};
    }
    NSString *rabin2 = [SPUtil findExecutable:@[@"rabin2"] searchDirs:[self searchDirs]];
    if (!rabin2) {
        if (error) *error = SPError(SPErrorCodeMissingToolchain, @"需要逆向工具（rabin2），请在工具链页下载");
        return @{};
    }

    // rabin2 -zz 列出字符串；再按 __objc_ 相关的段归类
    NSString *script = [NSString stringWithFormat:
        @"%@ -zz -q %@ 2>/dev/null", [SPUtil shellQuote:rabin2], [SPUtil shellQuote:binaryPath]];
    SPCommandResult *r = [SPSession runSyncShell:script environment:@{} cwd:NSTemporaryDirectory() timeout:180];
    NSString *out = r.stdoutText ?: @"";

    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    NSMutableSet *pendingClasses = [NSMutableSet set];
    NSMutableArray *methods = [NSMutableArray array];

    // ObjC 类名通常出现在 __objc_classname 段，方法名在 __objc_methname
    // rabin2 的 -zz 会带段名前缀，形如 "0x1234 0x10 __objc_classname NNN Name"
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if (line.length < 8) continue;
        // 提取最后一段作为字符串内容
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count < 5) continue;
        NSString *name = parts.lastObject;
        if (!name.length) continue;

        if ([line containsString:@"__objc_classname"]) {
            if ([self looksLikeClassName:name]) [pendingClasses addObject:name];
        } else if ([line containsString:@"__objc_methname"]) {
            // 方法名带冒号，或者 TypeEncodings 里的名字
            if ([name containsString:@":"] || [self looksLikeMethodName:name]) [methods addObject:name];
        }
    }

    // 没有段信息（普通 -zz）时，用启发式：大写开头的 identifier 当类名
    if (!pendingClasses.count) {
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSString *name = [line componentsSeparatedByString:@" "].lastObject;
            if (name.length < 2 || name.length > 60) continue;
            if ([self looksLikeClassName:name]) [pendingClasses addObject:name];
        }
    }

    // 方法按「最可能属于谁」粗略分配：先全放到 _Uncategorized
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *m in methods) if (![all containsObject:m]) [all addObject:m];
    [all sortUsingSelector:@selector(compare:)];

    for (NSString *cls in pendingClasses) {
        classes[cls] = [all copy];
    }
    if (!classes.count) classes[@"_Uncategorized"] = [all copy];
    return classes;
}

+ (NSArray<NSString *> *)searchDirs {
    NSMutableArray *d = [NSMutableArray array];
    NSString *bin = SPToolchainInstallerBinDir();
    if (bin.length) [d addObject:bin];
    NSString *rev = [[[SPToolchain shared] scan] pathFor:SPToolchainComponentReverse];
    if (rev.length) [d addObject:rev];
    [d addObjectsFromArray:@[@"/usr/bin", @"/var/jb/usr/bin", @"/usr/local/bin", @"/bin"]];
    return d;
}

+ (BOOL)looksLikeClassName:(NSString *)s {
    if (s.length < 2 || s.length > 64) return NO;
    unichar c = [s characterAtIndex:0];
    if (!(c == '_' || (c >= 'A' && c <= 'Z'))) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    return [s rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

+ (BOOL)looksLikeMethodName:(NSString *)s {
    if (s.length < 2 || s.length > 100) return NO;
    unichar c = [s characterAtIndex:0];
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

+ (void)exportHeadersFromApp:(NSString *)appPath
                   outputDir:(NSString *)outputDir
                    progress:(void (^)(NSString *))progress
                  completion:(void (^)(BOOL, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^report)(NSString *) = ^(NSString *s) {
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(s); });
        };

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *execName = [SPUtil stringFromPlistAtPath:[appPath stringByAppendingPathComponent:@"Info.plist"]
                                                      key:@"CFBundleExecutable" default:@""];
        NSString *binary = execName.length ? [appPath stringByAppendingPathComponent:execName] : nil;
        if (!binary || ![fm fileExistsAtPath:binary]) {
            // 允许直接传二进制路径
            if ([fm fileExistsAtPath:appPath] && ![appPath hasSuffix:@".app"]) binary = appPath;
        }
        if (!binary) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, 0, SPError(SPErrorCodeIO, @"找不到主二进制"));
            });
            return;
        }

        report(@"读取 ObjC 元数据…");
        NSError *err = nil;
        NSDictionary *classes = [self objcClassesAndMethodsInBinary:binary error:&err];
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, 0, err); });
            return;
        }

        report([NSString stringWithFormat:@"生成 %lu 个头文件…", (unsigned long)classes.count]);
        [fm createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:NULL];

        NSMutableString *allH = [NSMutableString string];
        [allH appendString:@"// 由 Workbench 从头文件导出\n"];
        [allH appendString:[NSString stringWithFormat:@"// 来源：%@\n", binary.lastPathComponent]];
        [allH appendString:@"// 注意：仅还原类名与方法名，方法签名按 selector 推断，不保证与原声明一致\n\n"];

        NSInteger count = 0;
        for (NSString *cls in [classes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSArray *methods = classes[cls];
            NSMutableString *h = [NSMutableString string];
            [h appendString:@"#import <Foundation/Foundation.h>\n#import <UIKit/UIKit.h>\n\n"];
            [h appendFormat:@"@interface %@ : NSObject\n", cls];
            for (NSString *m in methods) {
                [h appendFormat:@"- (void)%@;\n", m];
            }
            [h appendString:@"@end\n"];

            [h writeToFile:[outputDir stringByAppendingPathComponent:[cls stringByAppendingString:@".h"]]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [allH appendString:h];
            [allH appendString:@"\n"];
            count++;
        }
        [allH writeToFile:[outputDir stringByAppendingPathComponent:@"all.h"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        report([NSString stringWithFormat:@"完成：%ld 个类", (long)count]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES, count, nil);
        });
    });
}

@end

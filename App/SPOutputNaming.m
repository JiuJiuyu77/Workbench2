//
//  SPOutputNaming.m
//

#import "SPOutputNaming.h"
#import "SPCompat.h"

static NSString *const kDefaultDeb  = @"{name}_{version}_{packageArch}";
static NSString *const kDefaultTipa = @"{name}-{version}-{arch}";
static NSString *const kDefaultApp  = @"{name}-{version}";
static NSString *const kDefaultDylib = @"{name}";

@implementation SPOutputNaming

+ (NSArray<NSString *> *)availablePlaceholders {
    return @[@"{name}", @"{version}", @"{build}", @"{arch}", @"{packageArch}",
             @"{scheme}", @"{bundleId}", @"{date}", @"{time}"];
}

+ (NSString *)defaultPatternForExtension:(NSString *)ext {
    NSString *e = ext.lowercaseString;
    if ([e hasSuffix:@"deb"])   return kDefaultDeb;
    if ([e hasSuffix:@"tipa"])  return kDefaultTipa;
    if ([e hasSuffix:@"app"])   return kDefaultApp;
    if ([e hasSuffix:@"dylib"]) return kDefaultDylib;
    return @"{name}";
}

+ (NSString *)renderPattern:(NSString *)pattern
                    context:(NSDictionary<NSString *, NSString *> *)context {
    if (!pattern.length) return @"";
    NSMutableString *out = [pattern mutableCopy];

    // 日期时间：每次渲染都重新取
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSMutableDictionary *ctx = [context mutableCopy] ?: [NSMutableDictionary dictionary];
    df.dateFormat = @"yyyyMMdd";
    ctx[@"date"] = ctx[@"date"] ?: [df stringFromDate:[NSDate date]];
    df.dateFormat = @"HHmmss";
    ctx[@"time"] = ctx[@"time"] ?: [df stringFromDate:[NSDate date]];

    for (NSString *key in [self availablePlaceholders]) {
        NSString *bare = [key stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"{}"]];
        NSString *val = ctx[bare];
        if (![val isKindOfClass:[NSString class]] || !val.length) {
            val = ctx[bare] ? [ctx[bare] description] : @"";
        }
        [out replaceOccurrencesOfString:key withString:val
                                options:0 range:NSMakeRange(0, out.length)];
    }

    // 文件名里不能出现的字符，替换成 -
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>| "];
    NSString *clean = [[out componentsSeparatedByCharactersInSet:bad]
                       componentsJoinedByString:@"-"];

    // 连续 - 折叠
    while ([clean containsString:@"--"]) {
        clean = [clean stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    }
    return clean;
}

+ (NSString *)validatePattern:(NSString *)pattern {
    if (!pattern.length) return @"模板不能为空";

    NSArray *known = [self availablePlaceholders];
    // 找出所有 {xxx}
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\{[a-zA-Z]+\\}"
                                                                       options:0 error:NULL];
    NSArray *matches = [re matchesInString:pattern options:0 range:NSMakeRange(0, pattern.length)];
    for (NSTextCheckingResult *m in matches) {
        NSString *token = [pattern substringWithRange:m.range];
        if (![known containsObject:token]) {
            return [NSString stringWithFormat:@"未知占位符 %@", token];
        }
    }

    // 至少要有 name，否则所有产物会同名
    if (![pattern containsString:@"{name}"]) {
        return @"模板里必须有 {name}，否则产物会互相覆盖";
    }
    return nil;
}

+ (NSDictionary<NSString *, NSString *> *)contextForProject:(NSString *)projectPath {
    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *name = projectPath.lastPathComponent;
    NSString *version = @"1.0.0";
    NSString *packageArch = @"iphoneos-arm";
    NSString *scheme = @"rootful";
    NSString *bundleId = @"";

    // control
    NSString *controlPath = [projectPath stringByAppendingPathComponent:@"control"];
    NSString *control = [NSString stringWithContentsOfFile:controlPath
                                                  encoding:NSUTF8StringEncoding error:NULL];
    if (control) {
        for (NSString *line in [control componentsSeparatedByString:@"\n"]) {
            NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([l hasPrefix:@"Version:"]) {
                version = [l substringFromIndex:8];
                version = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            } else if ([l hasPrefix:@"Architecture:"]) {
                packageArch = [l substringFromIndex:13];
                packageArch = [packageArch stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            } else if ([l hasPrefix:@"Package:"]) {
                bundleId = [l substringFromIndex:8];
                bundleId = [bundleId stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
        }
    }

    // Makefile：产品名 / 架构
    NSString *makefilePath = [projectPath stringByAppendingPathComponent:@"Makefile"];
    NSString *makefile = [NSString stringWithContentsOfFile:makefilePath
                                                   encoding:NSUTF8StringEncoding error:NULL];
    if (makefile) {
        for (NSString *line in [makefile componentsSeparatedByString:@"\n"]) {
            NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([l hasPrefix:@"TWEAK_NAME"] || [l hasPrefix:@"APPLICATION_NAME"] ||
                [l hasPrefix:@"TOOL_NAME"] || [l hasPrefix:@"BUNDLE_NAME"]) {
                NSRange eq = [l rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    name = [l substringFromIndex:eq.location + 1];
                    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                }
            } else if ([l hasPrefix:@"ARCHS"]) {
                NSRange eq = [l rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    ctx[@"arch"] = [[l substringFromIndex:eq.location + 1]
                                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                }
            } else if ([l hasPrefix:@"THEOS_PACKAGE_SCHEME"]) {
                NSRange eq = [l rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    scheme = [[l substringFromIndex:eq.location + 1]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                }
            }
        }
    }

    ctx[@"name"] = name ?: @"untitled";
    ctx[@"version"] = version;
    ctx[@"build"] = ctx[@"build"] ?: @"1";
    ctx[@"arch"] = ctx[@"arch"] ?: @"arm64";
    ctx[@"packageArch"] = packageArch;
    ctx[@"scheme"] = scheme;
    ctx[@"bundleId"] = bundleId;
    return ctx;
}

@end

//
//  SPCompat.m
//

#import "SPCompat.h"

NSString *const SPErrorDomain = @"Workbench.Error";

id SPAtIndex(NSArray *array, NSInteger index, id fallback) {
    if (![array isKindOfClass:NSArray.class]) return fallback;
    if (index < 0 || index >= (NSInteger)array.count) return fallback;
    id v = array[(NSUInteger)index];
    return v ?: fallback;
}

#pragma mark - 日志（内存环形缓冲 + 文件）

static NSMutableArray<NSString *> *SPLogBuffer(void) {
    static NSMutableArray *buf;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ buf = [NSMutableArray array]; });
    return buf;
}

NSString *SPLogFilePath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Workbench/logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        p = [dir stringByAppendingPathComponent:@"workbench.log"];
    });
    return p;
}

void SPAppendLog(NSString *message) {
    if (!message.length) return;

    static NSDateFormatter *fmt;
    static dispatch_once_t fmtOnce;
    dispatch_once(&fmtOnce, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@", [fmt stringFromDate:NSDate.date], message];

    // 环形缓冲：最多 4000 条，避免长构建吃光内存
    NSMutableArray *buf = SPLogBuffer();
    @synchronized (buf) {
        [buf addObject:line];
        if (buf.count > 4000) [buf removeObjectsInRange:NSMakeRange(0, buf.count - 4000)];
    }

    // 落盘：用低层 API 追加，比每次读写整个文件快得多
    // 必须用**独立的** dispatch_once_t：
    // 之前两处共用同一个 once 变量，第一次已执行完，
    // 第二次直接跳过 → ioq 永远是 NULL → dispatch_async(NULL) → SIGSEGV。
    // 这个崩溃发生在启动阶段（elevateSelf 打日志时），表现为一启动就闪退。
    static dispatch_queue_t ioq;
    static dispatch_once_t ioOnce;
    dispatch_once(&ioOnce, ^{ ioq = dispatch_queue_create("workbench.log.io", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(ioq, ^{
        FILE *f = fopen(SPLogFilePath().fileSystemRepresentation, "a");
        if (!f) return;
        fprintf(f, "%s\n", line.UTF8String);
        fclose(f);
    });
}

NSArray<NSString *> *SPRecentLogs(NSUInteger limit) {
    NSMutableArray *buf = SPLogBuffer();
    @synchronized (buf) {
        NSUInteger n = MIN(limit, buf.count);
        return [buf subarrayWithRange:NSMakeRange(buf.count - n, n)];
    }
}

@implementation SPVersion

+ (instancetype)shared {
    static SPVersion *v; static dispatch_once_t once;
    dispatch_once(&once, ^{ v = [SPVersion new]; });
    return v;
}

- (NSString *)semver {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";
}

- (NSString *)gitDescribe {
    NSString *g = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SPGitDescribe"];
    return g.length ? g : @"dev";
}

- (NSString *)builtAt {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SPBuildDate"] ?: @"";
}

@end

@implementation SPUtil

+ (NSString *)formatDuration:(NSTimeInterval)seconds {
    NSInteger s = (NSInteger)MAX(0, seconds);
    if (s < 3600) return [NSString stringWithFormat:@"%02ld:%02ld", (long)(s / 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)((s % 3600) / 60), (long)(s % 60)];
}

+ (NSString *)formatBytes:(unsigned long long)bytes {
    static NSArray *units;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ units = @[@"B", @"KB", @"MB", @"GB", @"TB"]; });
    double v = (double)bytes; NSUInteger i = 0;
    while (v >= 1024.0 && i + 1 < units.count) { v /= 1024.0; i++; }
    return i == 0 ? [NSString stringWithFormat:@"%llu B", bytes]
                  : [NSString stringWithFormat:@"%.1f %@", v, units[i]];
}

+ (NSString *)shellQuote:(NSString *)s {
    if (s.length == 0) return @"''";
    // 不含特殊字符就直接返回，可读性更好
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-"];
    if ([s rangeOfCharacterFromSet:safe.invertedSet].location == NSNotFound) return s;
    NSMutableString *out = [NSMutableString stringWithString:@"'"];
    [out appendString:[s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    [out appendString:@"'"];
    return out;
}

+ (NSArray<NSString *> *)envPairsFromDictionary:(NSDictionary<NSString *, NSString *> *)dict {
    NSMutableArray *out = [NSMutableArray array];
    if (![dict isKindOfClass:[NSDictionary class]]) return out;
    // 只取字符串 key，且比较时也按 NSString 处理（避免数字 key 调用 compare: 崩）
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in dict.allKeys) if ([k isKindOfClass:[NSString class]]) [keys addObject:k];
    [keys sortUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        id raw = dict[k];
        if (![raw isKindOfClass:[NSString class]]) {
            if ([raw isKindOfClass:[NSNumber class]]) raw = [raw stringValue];
            else continue;
        }
        NSString *v = (NSString *)raw;
        // env 值里不能有换行，统统压成空格
        v = [v stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [out addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
    }
    return out;
}

+ (NSString *)stringFromPlistAtPath:(NSString *)path key:(NSString *)key default:(NSString *)def {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : def;
}

+ (NSString *)timestampSlug {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [f stringFromDate:[NSDate date]];
}

+ (NSError *)copyDirectory:(NSString *)src to:(NSString *)dst {
    NSFileManager *fm = NSFileManager.defaultManager;
    [self removeItemIfExists:dst];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES attributes:nil error:&err]) return err;
    if (![fm copyItemAtPath:src toPath:dst error:&err]) return err;
    return nil;
}

+ (void)removeItemIfExists:(NSString *)path {
    if (path.length) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
}

+ (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error {
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                   withIntermediateDirectories:YES attributes:nil error:error];
}

+ (NSString *)findExecutable:(NSArray<NSString *> *)names searchDirs:(NSArray<NSString *> *)dirs {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"/"]) { [candidates addObject:name]; continue; }
        for (NSString *d in dirs ?: @[]) [candidates addObject:[d stringByAppendingPathComponent:name]];
    }
    for (NSString *p in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && !isDir && [fm isExecutableFileAtPath:p]) return p;
    }
    // PATH 兜底
    NSString *PATH = [NSProcessInfo processInfo].environment[@"PATH"];
    for (NSString *d in [PATH componentsSeparatedByString:@":"]) {
        if (d.length == 0) continue;
        for (NSString *name in names) {
            if ([name hasPrefix:@"/"]) continue;
            NSString *p = [d stringByAppendingPathComponent:name];
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    return nil;
}

@end
//
//  SPAOJIT.m
//

#import "SPAOJIT.h"
#import "SPCompat.h"

/// 除管道符以外的 shell 元字符：出现任何一个就绝不走 AOJIT
static NSCharacterSet *SPNonPipeMetaSet(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @"&;<>$`()*?[]{}~!\\'\"\n\r\t"];
    });
    return set;
}

static NSCharacterSet *SPNewlineSet(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:@"\n\r"];
    });
    return set;
}

@interface SPAOJIT ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSArray<NSString *> *> *> *scriptCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *pathCache;
@property (nonatomic, assign) NSUInteger hits;
@property (nonatomic, assign) NSUInteger misses;
@property (nonatomic, assign) NSUInteger directs;
@property (nonatomic, strong) dispatch_queue_t q;
@end

@implementation SPAOJIT

+ (instancetype)shared {
    static SPAOJIT *o; static dispatch_once_t once;
    dispatch_once(&once, ^{
        o = [SPAOJIT new];
        o->_scriptCache = [NSMutableDictionary dictionary];
        o->_pathCache = [NSMutableDictionary dictionary];
        o->_userEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"Workbench.aojitEnabled"] == nil
            ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"Workbench.aojitEnabled"];
        o->_q = dispatch_queue_create("com.HuQing.Workbench.aojit", DISPATCH_QUEUE_SERIAL);
    });
    return o;
}

- (void)setUserEnabled:(BOOL)userEnabled {
    _userEnabled = userEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:userEnabled forKey:@"Workbench.aojitEnabled"];
    if (!userEnabled) [self reset];
}

- (NSUInteger)hitCount { return self.hits; }
- (NSUInteger)missCount { return self.misses; }
- (NSUInteger)directSpawnCount { return self.directs; }

- (void)reset {
    dispatch_sync(self.q, ^{
        [self.scriptCache removeAllObjects];
        [self.pathCache removeAllObjects];
        self.hits = 0;
        self.misses = 0;
        self.directs = 0;
    });
}

- (void)noteDirectSpawn {
    dispatch_async(self.q, ^{ self.directs++; });
}

- (NSString *)statusText {
    if (!self.userEnabled) return @"已关闭";
    NSUInteger h = self.hits, m = self.misses, d = self.directs;
    if (h + m == 0) return @"待命中（尚无调用）";
    return [NSString stringWithFormat:@"已省 %lu 次 sh 启动（直接执行 %lu，命中率 %.0f%%）",
            (unsigned long)h, (unsigned long)d,
            (h + m) ? (100.0 * h / (h + m)) : 0.0];
}

#pragma mark - PATH 解析

- (NSString *)resolveCommand:(NSString *)name
                 environment:(NSDictionary<NSString *, NSString *> *)env {
    if (!name.length) return nil;
    if ([name hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] isExecutableFileAtPath:name] ? name : nil;
    }
    NSString *path = env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    NSString *key = [path stringByAppendingFormat:@"\x1f%@", name];

    __block NSString *cached = nil;
    dispatch_sync(self.q, ^{ cached = self.pathCache[key]; });
    if (cached) return [cached isEqualToString:@"\x00"] ? nil : cached;

    NSString *found = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in [path componentsSeparatedByString:@":"]) {
        if (!dir.length) continue;
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:cand]) { found = cand; break; }
    }
    dispatch_async(self.q, ^{
        self.pathCache[key] = found ?: @"\x00";
        if (self.pathCache.count > 512) [self.pathCache removeAllObjects];
    });
    return found;
}

/// 把一段「无元字符的单命令」编译成 argv；失败返回 nil
- (NSArray<NSString *> *)argvForStage:(NSString *)stage
                          environment:(NSDictionary<NSString *, NSString *> *)env {
    NSString *t = [stage stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    if (!t.length) return nil;
    if ([t rangeOfCharacterFromSet:SPNonPipeMetaSet()].location != NSNotFound) return nil;

    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *w in [t componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]]) {
        if (w.length) [words addObject:w];
    }
    if (!words.count) return nil;

    NSString *exe = [self resolveCommand:words[0] environment:env];
    if (!exe) return nil;   // 命令不存在 → 交回 sh 报它原本的错误

    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:exe];
    if (words.count > 1) {
        [argv addObjectsFromArray:[words subarrayWithRange:NSMakeRange(1, words.count - 1)]];
    }
    return [argv copy];
}

#pragma mark - 脚本编译

- (NSArray<NSArray<NSString *> *> *)directStagesForScript:(NSString *)script
                                              environment:(NSDictionary<NSString *, NSString *> *)env {
    if (!self.userEnabled) return nil;
    if (!script.length) return nil;

    NSString *trimmed = [script stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return nil;
    // 多行脚本基本是构建流程，不碰
    if ([trimmed rangeOfCharacterFromSet:SPNewlineSet()].location != NSNotFound) return nil;

    // 缓存命中
    __block NSArray<NSArray<NSString *> *> *cached = nil;
    dispatch_sync(self.q, ^{ cached = self.scriptCache[trimmed]; });
    if (cached) {
        dispatch_async(self.q, ^{ self.hits++; });
        return cached.count ? cached : nil;
    }

    NSMutableArray<NSArray<NSString *> *> *stages = [NSMutableArray array];

    if ([trimmed rangeOfString:@"|"].location == NSNotFound) {
        NSArray *one = [self argvForStage:trimmed environment:env];
        if (one) [stages addObject:one];
    } else {
        // 有管道：先排除 `||`（逻辑或）与 `|&`（bash 扩展）
        if ([trimmed rangeOfString:@"||"].location != NSNotFound ||
            [trimmed rangeOfString:@"|&"].location != NSNotFound) {
            stages = nil;
        } else {
            for (NSString *part in [trimmed componentsSeparatedByString:@"|"]) {
                NSArray *argv = [self argvForStage:part environment:env];
                if (!argv) { stages = nil; break; }
                [stages addObject:argv];
            }
            if (stages.count < 2) stages = nil;   // 拆不开就当失败，回落 sh
        }
    }

    if (!stages.count) {
        dispatch_async(self.q, ^{ self.misses++; });
        return nil;
    }

    NSArray *result = [stages copy];
    dispatch_async(self.q, ^{
        self.scriptCache[trimmed] = result;
        if (self.scriptCache.count > 512) [self.scriptCache removeAllObjects];
        self.misses++;
    });
    return result;
}

- (NSArray<NSString *> *)directArgvForScript:(NSString *)script
                                 environment:(NSDictionary<NSString *, NSString *> *)env {
    NSArray<NSArray<NSString *> *> *stages =
        [self directStagesForScript:script environment:env];
    // 单命令才用这个入口（多段请用 directStagesForScript:）
    return stages.count == 1 ? stages.firstObject : nil;
}

@end

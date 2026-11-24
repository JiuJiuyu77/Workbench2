//
//  SPJIT.m
//

#import "SPJIT.h"
#import "SPCompat.h"
#import "SPJITService.h"
#import <sys/mman.h>
#import <mach/vm_statistics.h>

@implementation SPJIT

+ (instancetype)shared {
    static SPJIT *j; static dispatch_once_t once;
    dispatch_once(&once, ^{
        j = [SPJIT new];
        j->_userEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"Workbench.jitEnabled"] == nil
            ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"Workbench.jitEnabled"];
    });
    return j;
}

- (void)setUserEnabled:(BOOL)userEnabled {
    _userEnabled = userEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:userEnabled forKey:@"Workbench.jitEnabled"];
}

- (BOOL)isPlatformApp {
    // 有 no-sandbox 权限的 App 一定不是普通 App Store 签名
    // 这里用「能否读取 /private/var/containers/Bundle/Application」间接判断
    NSFileManager *fm = NSFileManager.defaultManager;
    return [fm isReadableFileAtPath:@"/private/var/containers/Bundle/Application"]
        || [fm isReadableFileAtPath:@"/var/jb/Library"]
        || [fm isReadableFileAtPath:@"/Applications"];
}

- (void)probe {
    // 1) 先试 JIT 子进程（最可靠：独立身份，能拿可执行内存）
    NSError *svcErr = nil;
    if ([[SPJITService shared] verifyExecutableMemoryWithError:&svcErr]) {
        _enabled = YES;
        _viaSubprocess = YES;
        _lastProbe = [NSDate date];
        SPLog(@"JIT 探测：可用（子进程 pid=%d）", (int)[[SPJITService shared] helperPid]);
        return;
    }

    // 2) 子进程不可用 → 退回主进程 mmap
    // 关键改动（迁移自 TrollAgent）：不再只判断「能不能 mmap 出可执行内存」，
    // 而是真的写一条 ret 并跳进去执行。mmap 成功但执行被内核杀的情况真实存在，
    // 只看分配结果会把不可用的设备误报成「可用」。
    //
    // 安全阀：真实执行在「签名不允许执行可写内存」的设备上会被内核直接 SIGKILL，
    // 连崩溃日志都来不及写。只有确认自己是平台级 App（TrollStore / 越狱）或
    // 已经是 root 时才做这一步；普通自签设备退回「只验证分配」的旧判据。
    BOOL canSafelyExec = self.isPlatformApp || getuid() == 0;
    void *p = [self allocateExecutable:4096];
    _viaSubprocess = NO;
    if (p) {
        [self freeExecutable:p size:4096];
        if (canSafelyExec) {
            _enabled = [self verifyExecutableByCalling];
        } else {
            _enabled = YES;
            SPLog(@"JIT 探测：非平台签名，跳过真实执行验证（避免被内核杀掉）");
        }
    } else {
        _enabled = NO;
    }
    _lastProbe = [NSDate date];
    SPLog(@"JIT 探测：%@（主进程；子进程原因：%@）",
          _enabled ? @"可用（已实际执行验证）" : @"不可用", svcErr.localizedDescription ?: @"-");
}

/// 启动时把 helper 拉起来（不阻塞主线程）
- (void)startServiceIfNeeded {
    if (!self.userEnabled) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[SPJITService shared] start];
        [self probe];
    });
}

- (void *)allocateExecutable:(size_t)size {
    if (!self.userEnabled) return NULL;

    // 1) 首选：RWX 直接映射（平台级 App 允许）
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (p != MAP_FAILED) return p;

    // 2) 退回：RW 映射后再 mprotect 成 RX（W^X 友好）
    p = mmap(NULL, size, PROT_READ | PROT_WRITE,
             MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (mprotect(p, size, PROT_READ | PROT_EXEC) != 0) {
        munmap(p, size);
        return NULL;
    }
    return p;
}

- (void)freeExecutable:(void *)ptr size:(size_t)size {
    if (ptr) munmap(ptr, size);
}

#pragma mark - 真实执行验证（迁移自 TrollAgent jit-check）

/// icache 失效。不能用 __builtin___clear_cache：它会生成对 ___clear_cache 的引用，
/// 而该符号在 iOS 的 libSystem 里没有导出，链接阶段就失败。
/// 也不用 libkern/OSCacheControl.h 的 sys_icache_invalidate：
/// iPhoneOS SDK 的 .tbd 里没有它的导出记录，部分 SDK 头里也没有声明，
/// 直接调用会报 implicit function declaration 并在链接时 undefined。
/// 因此这里只用内联汇编，零外部符号依赖。
static void SPInvalidateICache(void *start, size_t len) {
    uintptr_t p = (uintptr_t)start;
    uintptr_t end = p + len;
    // arm64 的 cache line 是 128 字节（CTR_EL0 里可查，这里按最小值 64 保守处理：
    // 多刷几次无害，少刷会留下陈旧指令）。
    const uintptr_t line = 64;
    for (uintptr_t a = p & ~(line - 1); a < end; a += line) {
        __asm__ __volatile__("ic ivau, %0" : : "r"(a) : "memory");
    }
    __asm__ __volatile__("dsb ish" ::: "memory");
    __asm__ __volatile__("isb" ::: "memory");
}

- (BOOL)verifyExecutableByCalling {
    if (!self.userEnabled) return NO;

    size_t sz = 4096;
    void *p = [self allocateExecutable:sz];
    if (!p) {
        SPLog(@"JIT 执行验证：拿不到可执行内存");
        return NO;
    }

    // arm64 的 ret = 0xd65f03c0，必须整体 4 字节小端写入。
    // 之前 spark-jitd 里只写 1 个字节（0xC0）既不是完整指令也没真调用，
    // 等于什么都没验证 —— 这里按 TrollAgent 修好后的写法来。
    uint32_t *code = (uint32_t *)p;
    code[0] = 0xd65f03c0u;              // ret
    SPInvalidateICache(p, sizeof(uint32_t));

    // 真的跳进去执行一次：能正常返回到下一行，才说明 PROT_EXEC 真的生效。
    // 若签名不允许执行可写内存，这里会被内核直接 SIGKILL（进程消失），
    // 这正是「探测 JIT 必须单独做、不能放进正常流程」的原因。
    int (*fn)(void) = (int (*)(void))p;
    volatile int r = fn();
    (void)r;

    munmap(p, sz);
    return YES;
}

- (NSString *)statusText {
    if (!self.userEnabled) return @"已关闭（设置里可开启）";
    if (!self.lastProbe) return @"未探测";
    if (self.enabled) {
        return self.viaSubprocess
            ? @"可用 · JIT 子进程"
            : @"可用 · 主进程分配";
    }
    NSString *helper = [SPJITService shared].helperPath;
    if (!helper) return @"不可用 —— 缺少 JIT 子进程（bin/spark-jitd）";
    return [NSString stringWithFormat:@"不可用 —— 子进程 %@，主进程也无可执行内存权限",
            [SPJITService shared].statusText];
}

@end

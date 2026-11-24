//
//  SPProcessGuard.m
//

#import "SPProcessGuard.h"
#import "SPCompat.h"
#import <spawn.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <pthread.h>
#import <stdlib.h>

// ── persona 私有 API ───────────────────────────────────────────────
// posix_spawnattr_t 在 C 里是 opaque 指针，函数签名按 TrollAgent 的写法。
typedef int (*SPSetPersonaFn)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*SPSetPersonaUIDFn)(posix_spawnattr_t *, uid_t);
typedef int (*SPSetPersonaGIDFn)(posix_spawnattr_t *, gid_t);

// POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 是私有宏，公开 SDK 的 spawn.h 不导出。
// 值 = 1，与 TrollAgent / TrollSpeed 一致。
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

static const uint32_t kRootPersonaID = 99;

@interface SPProcessGuard ()
@property (nonatomic, assign) BOOL personaAPIAvailable;
@property (nonatomic, copy) NSString *personaStatusText;
@property (nonatomic, assign) BOOL watchdogRunning;
@property (nonatomic, assign) pid_t originalParentPid;
@end

@implementation SPProcessGuard

+ (instancetype)shared {
    static SPProcessGuard *g;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [SPProcessGuard new];
        g.personaStatusText = @"未使用（子进程继承当前身份）";
        g.originalParentPid = getppid();

        // 符号探测：三个都要在，缺一个就不能用
        void *rtld = RTLD_DEFAULT;
        g.personaAPIAvailable =
            dlsym(rtld, "posix_spawnattr_set_persona_np") != NULL &&
            dlsym(rtld, "posix_spawnattr_set_persona_uid_np") != NULL &&
            dlsym(rtld, "posix_spawnattr_set_persona_gid_np") != NULL;
        if (g.personaAPIAvailable) {
            g.personaStatusText = @"可用（子进程可单独以 root 运行）";
        }
    });
    return g;
}

#pragma mark - persona 托管 spawn

- (SPChildIdentity)preferredIdentity {
    if (getuid() == 0) return SPChildIdentityInherit;   // 已经是 root，继承即可
    return self.personaAPIAvailable ? SPChildIdentityRootPersona : SPChildIdentityInherit;
}

- (BOOL)applyRootPersonaToAttr:(void *)attr {
    if (!attr) return NO;

    void *rtld = RTLD_DEFAULT;
    SPSetPersonaFn setPersona = (SPSetPersonaFn)dlsym(rtld, "posix_spawnattr_set_persona_np");
    SPSetPersonaUIDFn setUID = (SPSetPersonaUIDFn)dlsym(rtld, "posix_spawnattr_set_persona_uid_np");
    SPSetPersonaGIDFn setGID = (SPSetPersonaGIDFn)dlsym(rtld, "posix_spawnattr_set_persona_gid_np");

    if (!setPersona || !setUID || !setGID) {
        self.personaStatusText = @"不可用 —— 系统未导出 persona 私有符号";
        return NO;
    }

    posix_spawnattr_t *a = (posix_spawnattr_t *)attr;
    int rp = setPersona(a, (uid_t)kRootPersonaID, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    int ru = setUID(a, 0);
    int rg = setGID(a, 0);

    if (rp != 0 || ru != 0 || rg != 0) {
        // 常见原因：App 缺 com.apple.private.persona-mgmt（TrollStore 签名丢失）
        self.personaStatusText = [NSString stringWithFormat:
            @"设置失败 —— persona=%d uid=%d gid=%d（可能缺少 persona-mgmt 权限）",
            rp, ru, rg];
        SPLog(@"persona 托管 spawn 失败：persona=%d uid=%d gid=%d", rp, ru, rg);
        return NO;
    }

    self.personaStatusText = @"生效 —— 子进程以 root persona(99) 运行";
    return YES;
}

#pragma mark - 父进程守护

// 线程参数：只传一个不可变快照，避免跨线程访问 self 的属性
typedef struct {
    pid_t parent;
    double interval;
} SPWatchdogCtx;

static volatile int g_watchdog_stop = 0;

static void *SPWatchdogMain(void *raw) {
    SPWatchdogCtx *ctx = (SPWatchdogCtx *)raw;
    pid_t expected = ctx->parent;
    useconds_t us = (useconds_t)(ctx->interval * 1000000.0);
    if (us < 100000) us = 100000;   // 最低 0.1s，别把 CPU 烧了
    free(ctx);

    while (!g_watchdog_stop) {
        usleep(us);
        if (g_watchdog_stop) break;

        pid_t now = getppid();
        // 1 = launchd。父进程被系统杀掉后，子进程会被过继给 launchd，
        // 这是最可靠的「父进程已死」判据（TrollAgent 的 boot.js 用 ppid 比较同理）。
        if (now != expected || now == 1) {
            SPLog(@"[守护] 父进程已消失（%d → %d），本进程自行退出",
                  (int)expected, (int)now);
            // 先给一次 SIGTERM，让 make 有机会清理临时文件；2 秒后硬杀
            kill(getpid(), SIGTERM);
            sleep(2);
            kill(getpid(), SIGKILL);
            break;
        }
    }
    return NULL;
}

- (void)startParentWatchdogWithInterval:(NSTimeInterval)interval {
    if (self.watchdogRunning) return;

    self.originalParentPid = getppid();

    // 关键：iOS App 由 launchd(1) 直接拉起，getppid() 天然就是 1。
    // 此时「父进程消失」判据恒成立，守护线程会在 2 秒后把 App 自己杀掉。
    // 只有父进程不是 launchd（被别的进程托管，如终端里跑）时守护才有意义。
    if (self.originalParentPid <= 1) {
        SPLog(@"父进程守护跳过：本进程由 launchd 拉起（ppid=1），无守护对象");
        self.watchdogRunning = NO;
        return;
    }

    g_watchdog_stop = 0;

    // 间隔先落到局部变量：ctx 归线程所有，线程可能立刻跑起来把它 free 掉，
    // 之后再用 ctx 取值就是 use-after-free。
    NSTimeInterval iv = interval > 0 ? interval : 2.0;

    SPWatchdogCtx *ctx = calloc(1, sizeof(SPWatchdogCtx));
    if (!ctx) return;
    ctx->parent = self.originalParentPid;
    ctx->interval = iv;

    pthread_t th;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&th, &a, SPWatchdogMain, ctx);
    pthread_attr_destroy(&a);

    if (rc != 0) {
        free(ctx);
        SPLog(@"[!] 父进程守护启动失败 rc=%d", rc);
        return;
    }
    self.watchdogRunning = YES;
    SPLog(@"父进程守护已启动（每 %.1fs 检查 ppid=%d）", iv, (int)self.originalParentPid);
}

- (void)stopParentWatchdog {
    g_watchdog_stop = 1;
    self.watchdogRunning = NO;
}

@end

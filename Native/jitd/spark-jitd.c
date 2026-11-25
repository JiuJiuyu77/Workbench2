//
//  spark-jitd.c
//  Workbench —— JIT 授权 helper（独立进程）
//
//  为什么需要独立进程：
//   · iOS 不允许进程同步调试自己，主 App 自己 ptrace 自己拿不到 JIT 授权；
//   · 由本 helper（TrollStore 下用 persona 99 以 root 身份拉起）对主 App 做
//     PT_ATTACHEXC → sleep → PT_DETACH，等效 TrollStore 的「允许 JIT」开关。
//     参考 opa334/TrollStore RootHelper/jit.m 与 zrrt/TrollAgent tools/jit_helper.c。
//
//  协议（AF_UNIX SOCK_STREAM，一行一条命令，回复一行）：
//    ping                → ok pong
//    jit-check           → ok 0x<addr>（本 helper 自己能否拿到可执行内存）
//    enable-jit <pid>    → ok attached / err <errno>
//    quit                → ok bye，退出
//
//  编译：xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0
//        -O2 -Wall spark-jitd.c -o bin/spark-jitd
//

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

// iOS SDK 不导出 sys/ptrace.h 里的 request 常量，与 TrollStore RootHelper 一致手动声明。
int ptrace(int request, pid_t pid, void *addr, int data);
#ifndef PT_DETACH
#define PT_DETACH 11
#endif
#ifndef PT_ATTACHEXC
#define PT_ATTACHEXC 14
#endif

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

// arm64e 上 MAP_JIT 内存默认写保护，写入前需要临时解锁。
// 符号在 libsystem 里以 pthread_jit_write_protect_np 导出；用 dlsym 以免老 SDK 链接失败。
extern void *dlsym(void *, const char *);
typedef void (*jit_write_protect_fn)(int enabled);
static jit_write_protect_fn jit_write_protect(void) {
    static jit_write_protect_fn fn;
    static int looked;
    if (!looked) {
        looked = 1;
        fn = (jit_write_protect_fn)dlsym((void *)-2 /* RTLD_DEFAULT */,
                                         "pthread_jit_write_protect_np");
    }
    return fn;
}

static void invalidate_icache(void *start, size_t len) {
    uintptr_t p = (uintptr_t)start;
    uintptr_t end = p + len;
    for (uintptr_t a = p & ~(uintptr_t)63; a < end; a += 64) {
        __asm__ __volatile__("ic ivau, %0" : : "r"(a) : "memory");
    }
    __asm__ __volatile__("dsb ish" ::: "memory");
    __asm__ __volatile__("isb" ::: "memory");
}

// 真的分配一块可执行内存并写一条 ret，验证本进程是否具备 JIT 能力。
static int jit_check(char *out, size_t cap) {
    size_t size = 4096;
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) {
        snprintf(out, cap, "err mmap %d", errno);
        return 1;
    }
    jit_write_protect_fn unlock = jit_write_protect();
    if (unlock) unlock(0);
    uint32_t *code = (uint32_t *)p;
    code[0] = 0xd65f03c0u; /* ret */
    invalidate_icache(p, sizeof(uint32_t));
    if (unlock) unlock(1);

    int (*fn)(void) = (int (*)(void))p;
    (void)fn();
    munmap(p, size);
    snprintf(out, cap, "ok 0x%llx", (unsigned long long)(uintptr_t)p);
    return 0;
}

static int enable_jit(pid_t pid, char *out, size_t cap) {
    if (pid <= 0) {
        snprintf(out, cap, "err pid");
        return 1;
    }
    if (ptrace(PT_ATTACHEXC, pid, 0, 0) == -1) {
        snprintf(out, cap, "err attach %d", errno);
        return 1;
    }
    usleep(100 * 1000); /* 与 TrollStore RootHelper 一致：100ms */
    if (ptrace(PT_DETACH, pid, 0, 0) == -1) {
        snprintf(out, cap, "err detach %d", errno);
        return 1;
    }
    snprintf(out, cap, "ok attached %d", (int)pid);
    return 0;
}

static void handle_line(char *line, char *out, size_t cap) {
    while (*line == ' ' || *line == '\t') line++;
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ')) {
        line[--n] = '\0';
    }
    if (!strncmp(line, "ping", 4)) {
        snprintf(out, cap, "ok pong");
    } else if (!strncmp(line, "jit-check", 9)) {
        jit_check(out, cap);
    } else if (!strncmp(line, "enable-jit", 10)) {
        const char *arg = line + 10;
        while (*arg == ' ') arg++;
        enable_jit((pid_t)strtol(arg, NULL, 10), out, cap);
    } else if (!strncmp(line, "quit", 4)) {
        snprintf(out, cap, "ok bye");
    } else if (*line) {
        snprintf(out, cap, "err unknown");
    } else {
        snprintf(out, cap, "err empty");
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: spark-jitd <socket-path>\n");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);

    const char *path = argv[1];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "spark-jitd: socket failed errno=%d\n", errno);
        return 1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "spark-jitd: bind %s failed errno=%d\n", path, errno);
        close(fd);
        return 1;
    }
    chmod(path, 0666);
    if (listen(fd, 8) != 0) {
        fprintf(stderr, "spark-jitd: listen failed errno=%d\n", errno);
        close(fd);
        unlink(path);
        return 1;
    }
    fprintf(stderr, "spark-jitd: listening %s uid=%d pid=%d\n", path, (int)getuid(), (int)getpid());

    int quit = 0;
    while (!quit) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        char line[512];
        ssize_t n = read(client, line, sizeof(line) - 1);
        if (n > 0) {
            line[n] = '\0';
            char out[256] = {0};
            handle_line(line, out, sizeof(out));
            if (!strncmp(line, "quit", 4)) quit = 1;
            size_t len = strlen(out);
            out[len] = '\n';
            (void)write(client, out, len + 1);
        }
        close(client);
    }
    close(fd);
    unlink(path);
    return 0;
}

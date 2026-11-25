//
//  CrashGuard.m
//  Workbench —— 崩溃现场留痕
//

#import "CrashGuard.h"
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

static NSString *WBCrashLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!documents.length) documents = NSTemporaryDirectory();
        path = [documents stringByAppendingPathComponent:@"Workbench-crash.log"];
    });
    return path;
}

static void WBAppend(NSString *text) {
    NSString *path = WBCrashLogPath();
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        @try { [handle seekToEndOfFile]; [handle writeData:data]; }
        @finally { [handle closeFile]; }
    } else {
        [data writeToFile:path atomically:YES];
    }
}

static NSString *WBBacktrace(void) {
    void *frames[64];
    int count = backtrace(frames, 64);
    char **symbols = backtrace_symbols(frames, count);
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < count; i++) {
        if (symbols && symbols[i]) [text appendFormat:@"  %s\n", symbols[i]];
    }
    if (symbols) free(symbols);
    return text;
}

static void WBExceptionHandler(NSException *exception) {
    @try {
        WBAppend([NSString stringWithFormat:
            @"\n===== %@ uncaught exception =====\nname: %@\nreason: %@\nuserInfo: %@\ncallStack:\n%@\n",
            NSDate.date, exception.name, exception.reason, exception.userInfo,
            [exception.callStackSymbols componentsJoinedByString:@"\n"]]);
    } @catch (__unused NSException *ignored) {
    }
}

static void WBSignalHandler(int signalNumber) {
    @try {
        WBAppend([NSString stringWithFormat:
            @"\n===== %@ signal %d =====\nbacktrace:\n%@\n",
            NSDate.date, signalNumber, WBBacktrace()]);
    } @catch (__unused NSException *ignored) {
    }
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

@implementation WBCrashGuard

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSetUncaughtExceptionHandler(&WBExceptionHandler);
        int watched[] = {SIGABRT, SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGTRAP};
        for (size_t i = 0; i < sizeof(watched) / sizeof(watched[0]); i++) {
            signal(watched[i], WBSignalHandler);
        }
        // 记录一次正常启动，方便区分「启动前」还是「运行中」崩溃。
        WBAppend([NSString stringWithFormat:@"\n===== %@ launch uid=%d pid=%d =====\n",
                  NSDate.date, (int)getuid(), (int)getpid()]);
    });
}

+ (NSString *)logPath {
    return [[NSFileManager defaultManager] fileExistsAtPath:WBCrashLogPath()] ? WBCrashLogPath() : nil;
}

@end

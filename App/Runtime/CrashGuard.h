//
//  CrashGuard.h
//  Workbench —— 崩溃现场留痕
//
//  目的：真机闪退时，系统 .ips 有时拿不到或不直观。这里在进程内挂
//  未捕获异常处理器 + SIGABRT/SIGSEGV/SIGBUS 等信号处理器，把
//  异常名、原因、调用栈写到 Documents/Workbench-crash.log，
//  下一次启动可以把这个文件发出来定位。
//
//  只记录，不吞异常：处理完仍然走系统默认行为（abort / 重新抛）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WBCrashGuard : NSObject

/// 在 application:didFinishLaunching 最前面调用一次。
+ (void)install;

/// 最近一次崩溃日志路径（没有则为 nil）
+ (nullable NSString *)logPath;

@end

NS_ASSUME_NONNULL_END

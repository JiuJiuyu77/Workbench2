//
//  SPNetworkMonitor.m
//

#import "SPNetworkMonitor.h"
#import "SPCompat.h"
#import <Network/Network.h>

NSString *const SPNetworkRestoredNotification = @"SPNetworkRestoredNotification";

@interface SPNetworkMonitor ()
@property (nonatomic, strong, nullable) nw_path_monitor_t monitor;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL isNetworkAvailable;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong, nullable) NSDate *lastRestoredAt;
@end

@implementation SPNetworkMonitor

+ (instancetype)shared {
    static SPNetworkMonitor *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [SPNetworkMonitor new];
        // 默认 YES：没开始监测之前不要谎报断网，否则下载器会一上来就挂起
        m.isNetworkAvailable = YES;
    });
    return m;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    self.queue = dispatch_queue_create("com.HuQing.Workbench.netmon", DISPATCH_QUEUE_SERIAL);

    nw_path_monitor_t mon = nw_path_monitor_create();
    if (!mon) {
        SPLog(@"[!] 网络监测不可用（nw_path_monitor_create 失败）");
        self.started = NO;
        return;
    }
    self.monitor = mon;

    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_queue(mon, self.queue);
    nw_path_monitor_set_update_handler(mon, ^(nw_path_t path) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        BOOL satisfied = (nw_path_get_status(path) == nw_path_status_satisfied);
        BOOL was = self.isNetworkAvailable;
        self.isNetworkAvailable = satisfied;

        // 只在「不可用 → 可用」这个跳变上通知，避免网络抖动时反复触发重试
        if (satisfied && !was) {
            self.lastRestoredAt = [NSDate date];
            SPLog(@"网络已恢复，通知挂起的下载重试");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:SPNetworkRestoredNotification object:nil];
            });
        } else if (!satisfied && was) {
            SPLog(@"网络已断开");
        }
    });
    nw_path_monitor_start(mon);
}

- (void)stop {
    if (self.monitor) {
        nw_path_monitor_cancel(self.monitor);
        self.monitor = nil;
    }
    self.started = NO;
}

@end

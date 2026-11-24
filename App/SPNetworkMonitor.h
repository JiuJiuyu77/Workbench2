//
//  SPNetworkMonitor.h
//  Workbench —— 网络可达性监测与恢复通知
//
//  迁移自 TrollAgent 的 AppLifecycleMonitor：
//   TrollAgent 用 NWPathMonitor 盯着网络，一旦「从不满足变成满足」就发一条通知，
//   让上层把失败的任务重新排上。
//
//  Workbench 的问题：
//   工具链 / SDK 动辄几十上百 MB，下载到一半切到弱网、进地铁、开飞行模式，
//   NSURLSession 直接报错，三个镜像全试完就结束了。用户回来还得手动再点一次，
//   而且不知道是「网断了」还是「真没资源」。
//
//  做法：
//   · 持续监测 NWPath 状态
//   · 网络从「不可用」恢复到「可用」时发 SPNetworkRestoredNotification
//   · 下载器订阅它，把因网络失败挂起的组件自动重排
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 网络从不可用恢复为可用（主线程投递）
extern NSString *const SPNetworkRestoredNotification;

@interface SPNetworkMonitor : NSObject

+ (instancetype)shared;

/// 开始监测（幂等）
- (void)start;

/// 停止监测
- (void)stop;

/// 当前是否有网络（未开始监测时默认 YES，避免误判成断网）
@property (nonatomic, readonly) BOOL isNetworkAvailable;

/// 最近一次「网络恢复」的时间（nil 表示还没发生过）
@property (nonatomic, readonly, strong, nullable) NSDate *lastRestoredAt;

@end

NS_ASSUME_NONNULL_END

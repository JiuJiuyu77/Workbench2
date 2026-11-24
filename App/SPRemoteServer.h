//
//  SPRemoteServer.h
//  Workbench —— 局域网工作台（手机起 HTTP 服务，电脑浏览器直接用）
//
//  参考 Dylix Remote，但按巨魔环境重做：
//   · 自带极简 HTTP 服务（BSD socket + GCD，不引第三方库）
//   · 网页内嵌在 App 里，不联网也能用
//   · 鉴权：一次性随机码 or 固定码（存 Keychain），每个请求校验
//   · 只监听局域网地址，默认关闭
//   · 能力：列目录 / 读文件 / 写文件 / 新建 / 删除 / 触发构建 / 拉构建日志
//
//  安全边界（明确写在这里，也写进网页）：
//   · 只读/写当前选定的项目根目录，不能越界
//   · 写操作需要网页端确认（POST 带 confirm=1）
//   · HTTP 明文，仅限可信局域网
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPRemoteState) {
    SPRemoteStateStopped = 0,
    SPRemoteStateRunning,
    SPRemoteStateFailed,
};

@interface SPRemoteServer : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) SPRemoteState state;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) NSInteger port;
/// 形如 http://192.168.1.8:8787
@property (nonatomic, readonly, nullable) NSString *baseURL;
/// 一次性访问码（每次启动重新生成）
@property (nonatomic, readonly, nullable) NSString *accessCode;
@property (nonatomic, readonly) NSString *statusText;
/// 允许访问的项目根目录（可空 = 允许 Documents 下所有工程）
@property (nonatomic, copy, nullable) NSString *allowedRoot;

- (BOOL)startWithPort:(NSInteger)port error:(NSError *_Nullable *_Nullable)error;
- (void)stop;

/// 生成新的访问码
- (NSString *)rotateAccessCode;

/// 本机所有局域网 IPv4 地址
- (NSArray<NSString *> *)localIPv4Addresses;

@end

NS_ASSUME_NONNULL_END

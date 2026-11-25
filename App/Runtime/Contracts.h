#import <Foundation/Foundation.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif
NS_ASSUME_NONNULL_BEGIN

// 工作区工具回调：JSON 字典跨模块边界，错误用 NSError 表达。
typedef void (^TFAIResult)(NSDictionary * _Nullable result, NSError * _Nullable error);

// 远程工作台只把这个协议当作「可空指针」保存，实际执行走本地 TFAIToolbox。
@protocol TFAIRuntime <NSObject>
- (void)send:(NSArray<NSDictionary *> *)messages session:(NSString *)sessionID;
- (void)stop;
@end

// Tool schemas are OpenAI function objects {name,description,parameters}.
// Requests: {id,name,arguments:object}. prepare has NO side effects.
@interface TFAIToolbox : NSObject
- (instancetype)initWithRoot:(NSString *)root projectID:(NSString *)projectID sessionID:(NSString *)sessionID;
@property(nonatomic,copy,nullable) void (^bridge)(NSString *name, NSDictionary *arguments, TFAIResult completion);
+ (NSArray<NSDictionary *> *)schemas;
- (void)prepare:(NSDictionary *)request completion:(TFAIResult)completion;
- (void)prepareImportedTexts:(NSArray<NSDictionary *> *)files destination:(NSString *)destination completion:(TFAIResult)completion;
- (void)selectEdits:(NSArray<NSNumber *> *)indexes plan:(NSDictionary *)plan completion:(TFAIResult)completion;
- (void)setApprovalContext:(NSString *)context;
- (void)execute:(NSDictionary *)plan approved:(BOOL)approved completion:(TFAIResult)completion;
- (void)undo:(TFAIResult)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END

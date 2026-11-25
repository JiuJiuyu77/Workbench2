#import "Contracts.h"
NS_ASSUME_NONNULL_BEGIN

// 附件与项目相关的少量入口（实现在 Runtime/Attachments 与 Studio）。
FOUNDATION_EXPORT void TFAIImportAttachmentURLs(NSArray<NSURL *> *urls, void (^completion)(NSArray<NSDictionary *> *, NSError * _Nullable));
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable TFAIResolveAttachments(NSArray<NSDictionary *> *entries, NSError **error);
FOUNDATION_EXPORT NSArray<NSDictionary *> *TFAIInternalProjects(void); // Documents/Projects 下的项目

NS_ASSUME_NONNULL_END

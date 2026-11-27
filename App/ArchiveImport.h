#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TMCArchiveErrorCode) {
    TMCArchiveInvalid = 1,
    TMCArchivePassword = 2,
    TMCArchiveCancelled = 3,
    TMCArchiveLimit = 4,
    TMCArchiveProjectInvalid = 5,
};

typedef void (^TMCArchiveProgress)(NSUInteger files, unsigned long long bytes);

// Extracts into a new, private directory. No external commands or code execution.
BOOL TMCExtractArchive(NSURL *input, NSURL *destination, NSString *password,
                       NSProgress *cancellation, TMCArchiveProgress progress, NSError **error);
/// 把目录打成 zip（IPA 用）；entryPrefix 形如 "Payload/MyApp.app"。
/// 保留可执行位与相对符号链接，不跟随链接。
BOOL TMCZipDirectory(NSString *directory, NSString *zipPath, NSString *entryPrefix, NSError **error);

BOOL TMCExtractDebPackage(NSURL *input, NSURL *destination,
                          NSProgress *cancellation, TMCArchiveProgress progress, NSError **error);
NSArray<NSDictionary *> *TMCArchiveProjects(NSString *root, NSProgress *cancellation, NSError **error);
// Preserves an existing manifest; creates one for a plain source/Theos directory.
NSDictionary *TMCPrepareImportedProject(NSString *root, NSString *fallbackName, NSError **error);

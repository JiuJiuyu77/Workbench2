#import <Foundation/Foundation.h>

// These errors contain an allowlisted diagnostic report, never request credentials or bodies.
FOUNDATION_EXPORT NSString *const FLEXWorkbenchConnectionDiagnosticKey;
FOUNDATION_EXPORT NSError *FLEXWorkbenchConnectionError(NSString *host, NSUInteger port, NSString *path,
                                                  NSString *stage, NSInteger posixCode, NSInteger httpStatus);
FOUNDATION_EXPORT NSDictionary *FLEXWorkbenchHTTPRequest(NSString *host, NSUInteger port, NSString *path,
                                                    NSDictionary *body, NSString *token, NSString *csrf,
                                                    NSTimeInterval timeout, NSString **newToken, NSError **error);

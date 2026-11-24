#import <Foundation/Foundation.h>

// Scoped to the injected host App. No credentials are embedded in the dylib.
@interface FLEXWorkbenchPreferences : NSObject
+ (NSDictionary *)loadState;
+ (BOOL)saveState:(NSDictionary *)state error:(NSError **)error;
+ (BOOL)clearAuthorization:(NSError **)error;
+ (BOOL)clearAll:(NSError **)error;
@end

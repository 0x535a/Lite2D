#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// ZIP-only, bounded extraction into a new private staging directory.
@interface L2DModelArchive : NSObject
+ (BOOL)extractPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error NS_SWIFT_NAME(extract(path:toDirectory:));
@end
NS_ASSUME_NONNULL_END

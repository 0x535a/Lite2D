#import <Foundation/Foundation.h>
@interface L2DLegacyHost : NSObject
- (BOOL)loadPath:(NSString*)path error:(NSError**)error;
- (void)step:(double)dt lookX:(float)x lookY:(float)y;
- (void)renderWidth:(int)width height:(int)height scale:(float)scale;
- (BOOL)playGroup:(NSString*)group index:(int)index;
- (BOOL)selectExpression:(NSString*)name;
- (void)setMotionWeights:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)weights;
- (void)setIdleGroup:(NSString*)group;
@property(nonatomic,readonly) NSDictionary<NSString*,NSNumber*>* motionGroups;
@property(nonatomic,readonly) NSArray<NSString*>* expressionNames;
@property(nonatomic,readonly) float canvasAspect;
@end

#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface L2DBridge : NSObject
+ (BOOL)startRuntimeAt:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(startRuntime(at:));
+ (void)stopRuntime;
- (BOOL)loadPath:(NSString *)path width:(int)width height:(int)height error:(NSError **)error NS_SWIFT_NAME(load(path:width:height:));
- (void)step:(double)dt lookX:(float)x lookY:(float)y NS_SWIFT_NAME(step(deltaTime:lookX:lookY:));
- (void)renderWidth:(int)width height:(int)height scale:(float)scale NS_SWIFT_NAME(render(width:height:scale:));
- (BOOL)playGroup:(NSString *)group index:(int)index NS_SWIFT_NAME(play(group:index:));
- (BOOL)playInteraction:(NSString *)group;
@property(nonatomic, readonly) BOOL interactionPlaying;
- (BOOL)selectExpression:(NSString *)name;
- (void)setMotionWeights:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)weights;
- (void)setIdleGroup:(NSString *)group;
- (void)unload;
- (void)beginGPUMeasurement;
- (void)endGPUMeasurement;
@property(nonatomic, readonly) BOOL gpuTimingAvailable;
@property(nonatomic, readonly) unsigned long long gpuNanoseconds;
@property(nonatomic, readonly) unsigned long long gpuMeasuredFrames;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *motionGroups;
@property(nonatomic, readonly) NSArray<NSString *> *expressionNames;
@property(nonatomic, readonly) float canvasAspect;
@end
NS_ASSUME_NONNULL_END

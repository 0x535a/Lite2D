#import "Live2DBridge.h"
#include "NativeHost.hpp"
#include <exception>

static void fail(NSError** error,const char* message) {
 if(error)*error=[NSError errorWithDomain:@"Lite2D" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:message]?:@"Engine error"}];
}
@implementation L2DBridge {
 std::unique_ptr<Lite2D::NativeHost> _native;
}
+ (BOOL)startRuntimeAt:(NSString*)path error:(NSError**)error {
 try{Lite2D::startRuntime(path.UTF8String);return YES;}catch(const std::exception& e){fail(error,e.what());return NO;}
}
+ (void)stopRuntime {Lite2D::stopRuntime();}
- (BOOL)loadPath:(NSString*)path width:(int)width height:(int)height error:(NSError**)error {
 try{
  auto next=std::make_unique<Lite2D::NativeHost>();next->load(path.UTF8String,width,height);_native=std::move(next);return YES;
 }catch(const std::exception& e){fail(error,e.what());return NO;}
}
- (void)step:(double)dt lookX:(float)x lookY:(float)y {if(_native)_native->update(dt,x,y);}
- (void)renderWidth:(int)width height:(int)height scale:(float)scale {if(_native)_native->render(width,height,scale);}
- (BOOL)playGroup:(NSString*)group index:(int)index {return _native&&_native->play(group.UTF8String,index);}
- (BOOL)selectExpression:(NSString*)name {return _native&&_native->expression(name.UTF8String);}
- (void)setIdleGroup:(NSString*)group {if(_native)_native->idle(group.UTF8String);}
- (void)unload {_native.reset();}
- (NSDictionary<NSString*,NSNumber*>*)motionGroups {
 NSMutableDictionary* result=[NSMutableDictionary dictionary];
 if(_native)for(auto& pair:_native->groups())result[@(pair.first.c_str())]=@(pair.second);return result;
}
- (NSArray<NSString*>*)expressionNames {
 NSMutableArray* result=[NSMutableArray array];if(_native)for(auto& name:_native->expressions())[result addObject:@(name.c_str())];return result;
}
- (float)canvasAspect {return _native?_native->canvasAspect():1;}
@end

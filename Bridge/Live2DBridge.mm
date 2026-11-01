#import "Live2DBridge.h"
#include "NativeHost.hpp"
#import "LegacyHost.h"
#include <exception>

static void fail(NSError** error,const char* message) {
 if(error)*error=[NSError errorWithDomain:@"Lite2D" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:message]?:@"Engine error"}];
}
@implementation L2DBridge {
 std::unique_ptr<Lite2D::NativeHost> _native;
 L2DLegacyHost* _legacy;
}
+ (BOOL)startRuntimeAt:(NSString*)path error:(NSError**)error {
 try{Lite2D::startRuntime(path.UTF8String);return YES;}catch(const std::exception& e){fail(error,e.what());return NO;}
}
+ (void)stopRuntime {Lite2D::stopRuntime();}
- (BOOL)loadPath:(NSString*)path width:(int)width height:(int)height error:(NSError**)error {
 try{
  NSData* data=[NSData dataWithContentsOfFile:path options:0 error:error];if(!data)return NO;
  id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if(!parsed)return NO;
  if(![parsed isKindOfClass:NSDictionary.class]){fail(error,"Model description must be a JSON object");return NO;}
  NSDictionary* json=parsed;
  if([json[@"model"] isKindOfClass:NSString.class]) {
   L2DLegacyHost* next=[[L2DLegacyHost alloc]init];
   if(![next loadPath:path error:error])return NO;
   _native.reset();_legacy=next;return YES;
  }
  if(![json[@"FileReferences"] isKindOfClass:NSDictionary.class]){fail(error,"Invalid model description");return NO;}
  auto next=std::make_unique<Lite2D::NativeHost>();next->load(path.UTF8String,width,height);_native=std::move(next);_legacy=nil;return YES;
 }catch(const std::exception& e){fail(error,e.what());return NO;}
}
- (void)step:(double)dt lookX:(float)x lookY:(float)y {if(_native)_native->update(dt,x,y);else [_legacy step:dt lookX:x lookY:y];}
- (void)renderWidth:(int)width height:(int)height scale:(float)scale {if(_native)_native->render(width,height,scale);else [_legacy renderWidth:width height:height scale:scale];}
- (BOOL)playGroup:(NSString*)group index:(int)index {return _native?_native->play(group.UTF8String,index):[_legacy playGroup:group index:index];}
- (BOOL)selectExpression:(NSString*)name {return _native?_native->expression(name.UTF8String):[_legacy selectExpression:name];}
- (void)setIdleGroup:(NSString*)group {if(_native)_native->idle(group.UTF8String);else [_legacy setIdleGroup:group];}
- (void)unload {_native.reset();_legacy=nil;}
- (NSDictionary<NSString*,NSNumber*>*)motionGroups {
 if(_legacy)return _legacy.motionGroups;
 NSMutableDictionary* result=[NSMutableDictionary dictionary];
 if(_native)for(auto& pair:_native->groups())result[@(pair.first.c_str())]=@(pair.second);return result;
}
- (NSArray<NSString*>*)expressionNames {
 if(_legacy)return _legacy.expressionNames;
 NSMutableArray* result=[NSMutableArray array];if(_native)for(auto& name:_native->expressions())[result addObject:@(name.c_str())];return result;
}
- (float)canvasAspect {return _native?_native->canvasAspect():_legacy?_legacy.canvasAspect:1;}
@end

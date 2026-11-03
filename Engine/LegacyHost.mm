#include <GL/glew.h>
#import "LegacyHost.h"
#import <JavaScriptCore/JavaScriptCore.h>
#include <stb_image.h>
#include <set>
#include <map>
#include <algorithm>
#include <vector>

@implementation L2DLegacyHost {
 JSContext* _context;
 NSString* _lastError;
 std::map<std::string,std::set<GLuint>> _objects;
 NSDictionary* _settings;
 double _time;
}
- (void)dealloc {
 for(auto& group:_objects)for(GLuint value:group.second) {
  if(group.first=="Buffer")glDeleteBuffers(1,&value);
  if(group.first=="Texture")glDeleteTextures(1,&value);
  if(group.first=="Framebuffer")glDeleteFramebuffers(1,&value);
  if(group.first=="Renderbuffer")glDeleteRenderbuffers(1,&value);
  if(group.first=="Shader")glDeleteShader(value);
  if(group.first=="Program")glDeleteProgram(value);
 }
}
- (JSValue*)bytes:(NSData*)data {
 void* pointer=malloc(data.length);memcpy(pointer,data.bytes,data.length);
 JSObjectRef object=JSObjectMakeArrayBufferWithBytesNoCopy(_context.JSGlobalContextRef,pointer,data.length,
  [](void* bytes,void*){free(bytes);},nullptr,nullptr);
 return [JSValue valueWithJSValueRef:object inContext:_context];
}
- (id)glCall:(NSString*)name args:(JSValue*)args {
 auto a=[&](int i)->JSValue*{return [args valueAtIndex:i];};
 auto n=[&](int i)->GLuint{return a(i).toUInt32;};
 auto count=[&]()->int{return [args[@"length"] toInt32];};
 auto pointer=[&](int i)->void*{
  auto value=a(i);if(value.isNull||value.isUndefined)return nullptr;
  JSObjectRef object=(JSObjectRef)value.JSValueRef;
  size_t offset=JSObjectGetTypedArrayByteOffset(_context.JSGlobalContextRef,object,nullptr);
  auto* bytes=(unsigned char*)JSObjectGetTypedArrayBytesPtr(_context.JSGlobalContextRef,object,nullptr);
  return bytes?bytes+offset:nullptr;
 };
 auto length=[&](int i)->size_t{return JSObjectGetTypedArrayByteLength(_context.JSGlobalContextRef,(JSObjectRef)a(i).JSValueRef,nullptr);};
 std::string method=name.UTF8String;
 if([name hasPrefix:@"create"]) {
  GLuint object=0;std::string type=method.substr(6);
  if(type=="Buffer")glGenBuffers(1,&object);
  else if(type=="Texture")glGenTextures(1,&object);
  else if(type=="Framebuffer")glGenFramebuffers(1,&object);
  else if(type=="Renderbuffer")glGenRenderbuffers(1,&object);
  else if(type=="Shader")object=glCreateShader(n(0));
  else if(type=="Program")object=glCreateProgram();
  else goto unsupported;
  _objects[type].insert(object);return @(object);
 }
 if([name hasPrefix:@"delete"]) {
  GLuint object=n(0);std::string type=method.substr(6);
  if(type=="Buffer")glDeleteBuffers(1,&object);
  else if(type=="Texture")glDeleteTextures(1,&object);
  else if(type=="Framebuffer")glDeleteFramebuffers(1,&object);
  else if(type=="Renderbuffer")glDeleteRenderbuffers(1,&object);
  else if(type=="Shader")glDeleteShader(object);
  else if(type=="Program")glDeleteProgram(object);
  else goto unsupported;
  _objects[type].erase(object);return nil;
 }
#define CALL(NAME,EXPR) if([name isEqualToString:@#NAME]){EXPR;return nil;}
 CALL(activeTexture,glActiveTexture(n(0)))
 CALL(bindBuffer,glBindBuffer(n(0),n(1)))
 CALL(bindTexture,glBindTexture(n(0),n(1)))
 CALL(bindFramebuffer,glBindFramebuffer(n(0),n(1)))
 CALL(bindRenderbuffer,glBindRenderbuffer(n(0),n(1)))
 CALL(blendEquationSeparate,glBlendEquationSeparate(n(0),n(1)))
 CALL(blendFuncSeparate,glBlendFuncSeparate(n(0),n(1),n(2),n(3)))
 CALL(enable,glEnable(n(0)))
 CALL(disable,glDisable(n(0)))
 CALL(frontFace,glFrontFace(n(0)))
 CALL(cullFace,glCullFace(n(0)))
 CALL(enableVertexAttribArray,glEnableVertexAttribArray(n(0)))
 CALL(disableVertexAttribArray,glDisableVertexAttribArray(n(0)))
 CALL(vertexAttribPointer,glVertexAttribPointer(n(0),n(1),n(2),a(3).toBool,n(4),(void*)(uintptr_t)n(5)))
 CALL(drawElements,glDrawElements(n(0),n(1),n(2),(void*)(uintptr_t)n(3)))
 CALL(useProgram,glUseProgram(n(0)))
 CALL(compileShader,glCompileShader(n(0)))
 CALL(attachShader,glAttachShader(n(0),n(1)))
 CALL(linkProgram,glLinkProgram(n(0)))
 CALL(uniform1i,glUniform1i(a(0).toInt32,a(1).toInt32))
 CALL(uniform4f,glUniform4f(a(0).toInt32,a(1).toDouble,a(2).toDouble,a(3).toDouble,a(4).toDouble))
 CALL(texParameteri,glTexParameteri(n(0),n(1),n(2)))
 CALL(texImage2D,glTexImage2D(n(0),a(1).toInt32,n(2),n(3),n(4),n(5),n(6),n(7),pointer(8)))
 CALL(renderbufferStorage,glRenderbufferStorage(n(0),n(1),n(2),n(3)))
 CALL(framebufferRenderbuffer,glFramebufferRenderbuffer(n(0),n(1),n(2),n(3)))
 CALL(framebufferTexture2D,glFramebufferTexture2D(n(0),n(1),n(2),n(3),n(4)))
 CALL(viewport,glViewport(a(0).toInt32,a(1).toInt32,n(2),n(3)))
 CALL(clearColor,glClearColor(a(0).toDouble,a(1).toDouble,a(2).toDouble,a(3).toDouble))
 CALL(clear,glClear(n(0)))
 CALL(colorMask,glColorMask(a(0).toBool,a(1).toBool,a(2).toBool,a(3).toBool))
 CALL(flush,glFlush())
#undef CALL
 if([name isEqual:@"bufferData"]){
  GLenum target=n(0),usage=n(2);bool numeric=a(1).isNumber;size_t size=numeric?n(1):length(1);
  void* bytes=numeric?nullptr:pointer(1);glBufferData(target,size,bytes,usage);return nil;
 }
 if([name isEqual:@"uniformMatrix4fv"]){
  GLint location=a(0).toInt32;GLsizei size=(GLsizei)(length(2)/(16*sizeof(float)));GLboolean transpose=a(1).toBool;
  auto* bytes=(float*)pointer(2);glUniformMatrix4fv(location,size,transpose,bytes);return nil;
 }
 if([name isEqual:@"shaderSource"]) {
  NSString* source=a(1).toString;
  NSRegularExpression* precision=[NSRegularExpression regularExpressionWithPattern:@"precision\\s+(lowp|mediump|highp)\\s+float\\s*;|\\b(lowp|mediump|highp)\\b" options:0 error:nil];
  source=[precision stringByReplacingMatchesInString:source options:0 range:NSMakeRange(0,source.length) withTemplate:@""];
  const char* text=source.UTF8String;glShaderSource(n(0),1,&text,nullptr);return nil;
 }
 if([name isEqual:@"getExtension"])return NSNull.null;
 if([name isEqual:@"getAttribLocation"])return @(glGetAttribLocation(n(0),a(1).toString.UTF8String));
 if([name isEqual:@"getUniformLocation"])return @(glGetUniformLocation(n(0),a(1).toString.UTF8String));
 if([name isEqual:@"getShaderParameter"]){GLint value;glGetShaderiv(n(0),n(1),&value);return @(value);}
 if([name isEqual:@"getProgramParameter"]){GLint value;glGetProgramiv(n(0),n(1),&value);return @(value);}
 if([name isEqual:@"getShaderInfoLog"]||[name isEqual:@"getProgramInfoLog"]){
  char text[8192]={0};if([name isEqual:@"getShaderInfoLog"])glGetShaderInfoLog(n(0),sizeof(text),nullptr,text);else glGetProgramInfoLog(n(0),sizeof(text),nullptr,text);return @(text);
 }
 if([name isEqual:@"getParameter"]){
  GLint value[4]={0};glGetIntegerv(n(0),value);
  if(n(0)==GL_VIEWPORT)return @[@(value[0]),@(value[1]),@(value[2]),@(value[3])];
  return @(value[0]);
 }
 if([name isEqual:@"getError"])return @(glGetError());
unsupported:
 _lastError=[@"Unsupported legacy GL operation: " stringByAppendingString:name];
 [JSContext currentContext].exception=[JSValue valueWithNewErrorFromMessage:_lastError inContext:_context];
 (void)count;return nil;
}
- (void)glBatch:(JSValue*)commands buffers:(JSValue*)buffers {
 // Copy the numeric command stream before making any further JSC API call:
 // typed-array backing-store pointers may move across those calls.
 JSObjectRef object=(JSObjectRef)commands.JSValueRef;
 size_t length=JSObjectGetTypedArrayByteLength(_context.JSGlobalContextRef,object,nullptr)/sizeof(double);
 size_t offset=JSObjectGetTypedArrayByteOffset(_context.JSGlobalContextRef,object,nullptr);
 auto* storage=(unsigned char*)JSObjectGetTypedArrayBytesPtr(_context.JSGlobalContextRef,object,nullptr);
 if(!storage)return;
 auto* start=(double*)(storage+offset);
 std::vector<double> stream(start,start+length);
 size_t cursor=0;
 auto next=[&]()->double {return cursor<stream.size()?stream[cursor++]:0;};
 while(cursor<stream.size()) {
  int op=(int)next();
  // Evaluate arguments in stream order, never as multiple next() calls in a
  // GL function's unspecified C++ argument evaluation order.
  double p[6]={0};
  static const int arity[]={1,2,2,2,2,2,4,1,1,1,1,1,1,6,4,1,2,5,3,4,4,1,4,3,3};
  if(op>=0&&op<25)for(int i=0;i<arity[op];++i)p[i]=next();
  switch(op) {
   case 0:glActiveTexture(p[0]);break;
   case 1:glBindBuffer(p[0],p[1]);break;
   case 2:glBindTexture(p[0],p[1]);break;
   case 3:glBindFramebuffer(p[0],p[1]);break;
   case 4:glBindRenderbuffer(p[0],p[1]);break;
   case 5:glBlendEquationSeparate(p[0],p[1]);break;
   case 6:glBlendFuncSeparate(p[0],p[1],p[2],p[3]);break;
   case 7:glEnable(p[0]);break;
   case 8:glDisable(p[0]);break;
   case 9:glFrontFace(p[0]);break;
   case 10:glCullFace(p[0]);break;
   case 11:glEnableVertexAttribArray(p[0]);break;
   case 12:glDisableVertexAttribArray(p[0]);break;
   case 13:glVertexAttribPointer(p[0],p[1],p[2],p[3]!=0,p[4],(void*)(uintptr_t)p[5]);break;
   case 14:glDrawElements(p[0],p[1],p[2],(void*)(uintptr_t)p[3]);break;
   case 15:glUseProgram(p[0]);break;
   case 16:glUniform1i(p[0],p[1]);break;
   case 17:glUniform4f(p[0],p[1],p[2],p[3],p[4]);break;
   case 18:glTexParameteri(p[0],p[1],p[2]);break;
   case 19:glViewport(p[0],p[1],p[2],p[3]);break;
   case 20:glClearColor(p[0],p[1],p[2],p[3]);break;
   case 21:glClear(p[0]);break;
   case 22:glColorMask(p[0]!=0,p[1]!=0,p[2]!=0,p[3]!=0);break;
   case 23: {
    JSValue* value=[buffers valueAtIndex:(NSUInteger)p[2]];
    JSObjectRef array=(JSObjectRef)value.JSValueRef;
    size_t bytes=JSObjectGetTypedArrayByteLength(_context.JSGlobalContextRef,array,nullptr);
    size_t base=JSObjectGetTypedArrayByteOffset(_context.JSGlobalContextRef,array,nullptr);
    auto* source=(unsigned char*)JSObjectGetTypedArrayBytesPtr(_context.JSGlobalContextRef,array,nullptr);
    glBufferData(p[0],bytes,source?source+base:nullptr,p[1]);break;
   }
   case 24:glBufferData(p[0],p[1],nullptr,p[2]);break;
   case 25: {
    GLint location=(GLint)next();GLboolean transpose=next()!=0;size_t count=(size_t)next();
    if(count>256||cursor+count*16>stream.size())return;
    std::vector<GLfloat> matrices(count*16);
    for(auto& value:matrices)value=(GLfloat)next();
    glUniformMatrix4fv(location,(GLsizei)count,transpose,matrices.data());break;
   }
   default:_lastError=@"Unknown GL batch opcode";return;
  }
 }
}
- (BOOL)loadPath:(NSString*)path error:(NSError**)error {
 glewExperimental=GL_TRUE;
 if(glewInit()!=GLEW_OK){if(error)*error=[NSError errorWithDomain:@"Lite2D.Legacy" code:2 userInfo:@{NSLocalizedDescriptionKey:@"GLEW initialization failed"}];return NO;}
 while(glGetError()!=GL_NO_ERROR){}
 _context=[[JSContext alloc]init];__weak L2DLegacyHost* weakSelf=self;
 _context.exceptionHandler=^(JSContext* context,JSValue* exception){
  L2DLegacyHost* host=weakSelf;if(host)host->_lastError=exception.toString;fprintf(stderr,"Legacy: %s\n",exception.toString.UTF8String);
 };
 _context[@"__gl"]=^id(NSString* name,JSValue* args){return [weakSelf glCall:name args:args];};
 _context[@"__glBatch"]=^(JSValue* commands,JSValue* buffers){[weakSelf glBatch:commands buffers:buffers];};
 _context[@"__log"]=^(NSString* text){fprintf(stderr,"Legacy SDK: %s\n",text.UTF8String);};
 NSMutableDictionary* constants=[NSMutableDictionary dictionary];
#define CONST(NAME) constants[@#NAME]=@(GL_##NAME)
 CONST(ARRAY_BUFFER);CONST(ELEMENT_ARRAY_BUFFER);CONST(STATIC_DRAW);CONST(DYNAMIC_DRAW);
 CONST(FLOAT);CONST(UNSIGNED_SHORT);CONST(UNSIGNED_BYTE);CONST(TRIANGLES);CONST(TRIANGLE_STRIP);
 CONST(TEXTURE_2D);CONST(TEXTURE0);CONST(TEXTURE1);CONST(TEXTURE2);CONST(RGBA);CONST(RGBA4);
 CONST(TEXTURE_MIN_FILTER);CONST(TEXTURE_MAG_FILTER);CONST(LINEAR);CONST(NEAREST);
 CONST(TEXTURE_WRAP_S);CONST(TEXTURE_WRAP_T);CONST(CLAMP_TO_EDGE);
 CONST(FRAMEBUFFER);CONST(RENDERBUFFER);CONST(COLOR_ATTACHMENT0);CONST(FRAMEBUFFER_BINDING);
 CONST(RENDERBUFFER_BINDING);CONST(VIEWPORT);CONST(TEXTURE_BINDING_2D);CONST(ACTIVE_TEXTURE);
 CONST(BLEND);CONST(DEPTH_TEST);CONST(STENCIL_TEST);CONST(SCISSOR_TEST);CONST(CULL_FACE);CONST(CCW);CONST(CW);
 CONST(SRC_ALPHA);CONST(ONE_MINUS_SRC_ALPHA);CONST(ONE_MINUS_SRC_COLOR);CONST(DST_COLOR);CONST(ZERO);CONST(ONE);
 CONST(FUNC_ADD);CONST(COLOR_BUFFER_BIT);CONST(VERTEX_SHADER);CONST(FRAGMENT_SHADER);
 CONST(COMPILE_STATUS);CONST(LINK_STATUS);CONST(MAX_TEXTURE_SIZE);CONST(MAX_TEXTURE_IMAGE_UNITS);
#undef CONST
 _context[@"glConstants"]=constants;
 NSString* resources=NSBundle.mainBundle.resourcePath;
 NSString* shim=[NSString stringWithContentsOfFile:[resources stringByAppendingPathComponent:@"legacy-host.js"] encoding:NSUTF8StringEncoding error:error];
 NSString* runtime=[NSString stringWithContentsOfFile:[resources stringByAppendingPathComponent:@"legacy-core.js"] encoding:NSUTF8StringEncoding error:error];
 if(!shim||!runtime)return NO;
 [_context evaluateScript:shim];[_context evaluateScript:runtime];
 NSData* json=[NSData dataWithContentsOfFile:path options:0 error:error];if(!json)return NO;
 _settings=[NSJSONSerialization JSONObjectWithData:json options:0 error:error];if(!_settings)return NO;
 NSString* directory=path.stringByDeletingLastPathComponent;
 NSData* moc=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:_settings[@"model"]] options:0 error:error];if(!moc)return NO;
 _context[@"modelBytes"]=[self bytes:moc];_context[@"settings"]=_settings;
 [_context evaluateScript:@"Live2D.setGL(gl); var model=Live2DModelWebGL.loadModel(modelBytes); modelBytes=null; if(Live2D.getError()) throw Error('Cubism 2 load error'); if(!(model.getCanvasWidth()>0)) throw Error('Empty legacy model'); model.setPremultipliedAlpha(true); model.saveParam();"];
 if(_lastError)goto failed;
 {
  NSArray* textures=_settings[@"textures"];
  for(NSUInteger i=0;i<textures.count;++i){
   NSData* image=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:textures[i]] options:0 error:error];if(!image)return NO;
   int w,h,n;auto* pixels=stbi_load_from_memory((const unsigned char*)image.bytes,(int)image.length,&w,&h,&n,4);
   if(!pixels){_lastError=@"Cannot decode legacy texture";goto failed;}
   // Cubism 2 WebGL expects image uploads with flipY=true and premultiplied RGB.
   // Do it once here, without changing stb's process-global decode settings.
   for(int y=0;y<h/2;++y)for(int x=0;x<w*4;++x)std::swap(pixels[y*w*4+x],pixels[(h-1-y)*w*4+x]);
   for(size_t p=0;p<(size_t)w*h*4;p+=4)for(int c=0;c<3;++c)pixels[p+c]=(pixels[p+c]*pixels[p+3]+127)/255;
   GLuint texture;glGenTextures(1,&texture);_objects["Texture"].insert(texture);glBindTexture(GL_TEXTURE_2D,texture);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);stbi_image_free(pixels);
   [_context[@"model"]invokeMethod:@"setTexture" withArguments:@[@(i),@(texture)]];
  }
  NSDictionary* motions=_settings[@"motions"];
  for(NSString* group in motions) {
   NSArray* list=motions[group];
   for(NSUInteger i=0;i<list.count;++i){
    NSString* file=list[i][@"file"];if(!file)continue;
    NSData* data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
    if(data){_context[@"motionBytes"]=[self bytes:data];[_context[@"registerMotion"]callWithArguments:@[group,@(i),list[i]]];}
   }
  }
 }
 [_context evaluateScript:@"initializeLegacy(); model.update();"];
 if(_lastError)goto failed;
 return YES;
failed:
 if(error)*error=[NSError errorWithDomain:@"Lite2D.Legacy" code:1 userInfo:@{NSLocalizedDescriptionKey:_lastError?:@"Legacy model load failed"}];return NO;
}
- (void)step:(double)dt lookX:(float)x lookY:(float)y {
 _time+=dt;[_context[@"stepLegacy"]callWithArguments:@[@(_time),@(x),@(y)]];
}
- (void)renderWidth:(int)width height:(int)height scale:(float)scale {
 [_context[@"drawLegacy"]callWithArguments:@[@(width),@(height),@(scale)]];
}
- (BOOL)playGroup:(NSString*)group index:(int)index{return [[_context[@"playLegacy"]callWithArguments:@[group,@(index)]]toBool];}
- (BOOL)selectExpression:(NSString*)name {return [name isEqual:@""];}
- (void)setMotionWeights:(NSDictionary<NSString*,NSArray<NSNumber*>*>*)weights {_context[@"motionWeights"]=weights;}
- (void)setIdleGroup:(NSString*)group {[_context[@"setLegacyIdle"]callWithArguments:@[group]];}
- (NSDictionary<NSString*,NSNumber*>*)motionGroups {
 NSMutableDictionary* result=[NSMutableDictionary dictionary];NSDictionary* motions=_settings[@"motions"];
 for(NSString* group in motions) {
  NSArray* list=motions[group];BOOL playable=NO;
  for(NSDictionary* motion in list)if([motion[@"file"] isKindOfClass:NSString.class]){playable=YES;break;}
  if(playable)result[group]=@(list.count);
 }
 return result;
}
- (NSArray<NSString*>*)expressionNames {return @[];}
- (float)canvasAspect {return [[_context evaluateScript:@"model.getCanvasWidth()/model.getCanvasHeight()"]toDouble];}
@end

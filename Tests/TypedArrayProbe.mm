#import <JavaScriptCore/JavaScriptCore.h>
#include <cstdio>
int main(){@autoreleasepool {
 JSContext* context=[[JSContext alloc]init];
 JSValue* value=[context evaluateScript:@"var b=new ArrayBuffer(16);var a=new Uint8Array(b,4,4);a.set([11,22,33,44]);a"];
 JSObjectRef object=(JSObjectRef)value.JSValueRef;
 size_t offset=JSObjectGetTypedArrayByteOffset(context.JSGlobalContextRef,object,nullptr);
 auto* bytes=(unsigned char*)JSObjectGetTypedArrayBytesPtr(context.JSGlobalContextRef,object,nullptr);
 printf("offset=%zu pointer bytes=%u,%u,%u,%u\n",offset,bytes[0],bytes[1],bytes[2],bytes[3]);
}}

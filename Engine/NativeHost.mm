#include "NativeHost.hpp"
#import <Foundation/Foundation.h>
#include <GL/glew.h>
#include <CubismFramework.hpp>
#include <ICubismAllocator.hpp>
#include <CubismModelSettingJson.hpp>
#include <Model/CubismUserModel.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>
#include <Rendering/OpenGL/CubismOffscreenManager_OpenGLES2.hpp>
#include <Motion/CubismMotion.hpp>
#include <Motion/CubismExpressionUpdater.hpp>
#include <Motion/CubismPhysicsUpdater.hpp>
#include <Motion/CubismPoseUpdater.hpp>
#include <Motion/CubismBreathUpdater.hpp>
#include <Motion/CubismEyeBlinkUpdater.hpp>
#include <Motion/CubismLookUpdater.hpp>
#include <Physics/CubismPhysics.hpp>
#include <Id/CubismIdManager.hpp>
#include <filesystem>
#include <fstream>
#include <cstdlib>
#include <stdexcept>
#include <algorithm>
#include <random>
#include <cmath>
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

namespace Csm = Live2D::Cubism::Framework;
using namespace Csm;
using namespace Csm::Rendering;
namespace {
class Allocator : public ICubismAllocator {
public:
 void* Allocate(csmSizeType size) override {return std::malloc(size);}
 void Deallocate(void* p) override {std::free(p);}
 void* AllocateAligned(csmSizeType size,csmUint32 align) override {
   void* p=nullptr;return posix_memalign(&p,std::max<size_t>(align,sizeof(void*)),size)==0?p:nullptr;
 }
 void DeallocateAligned(void* p) override {std::free(p);}
} allocator;
bool started=false;
CubismFramework::Option options;
std::string shaderRoot;
std::vector<unsigned char> readFile(const std::string& path) {
 std::ifstream f(path,std::ios::binary);
 if(!f) throw Lite2D::LocalizedEngineError("error.engine_read", "Cannot read: "+path);
 return {std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};
}
std::vector<unsigned char> readJsonFile(const std::string& path) {
 // R5's numeric parser requires newlines/commas after numbers. Canonicalize
 // valid compact JSON at the host boundary without altering users' files.
 auto raw=readFile(path);
 NSData* data=[NSData dataWithBytes:raw.data() length:raw.size()];
 id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
 if(!object)throw Lite2D::LocalizedEngineError("error.engine_json", "Invalid model JSON: "+path);
 NSData* formatted=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
 if(!formatted)throw Lite2D::LocalizedEngineError("error.engine_normalize", "Cannot normalize model JSON: "+path);
 auto bytes=static_cast<const unsigned char*>(formatted.bytes);
 return {bytes,bytes+formatted.length};
}
csmByte* shaderFile(const std::string path,csmSizeInt* size) {
 try {
  auto data=readFile(shaderRoot+"/"+path);*size=(csmSizeInt)data.size();
  auto p=new csmByte[data.size()];std::copy(data.begin(),data.end(),p);return p;
 }catch(...){*size=0;return nullptr;}
}
void releaseFile(csmByte* bytes){delete[] bytes;}
// Keep the R5 scheduler's declared order (expression 300, look 400, breath
// 500, physics 600, pose 800) without applying CubismTargetPoint's extra
// smoothing on top of the host's time-based filter.
class DirectLookUpdater : public ICubismUpdater {
 const CubismLook& look;
 const float& x;
 const float& y;
public:
 DirectLookUpdater(const CubismLook& look,const float& x,const float& y)
  :ICubismUpdater(CubismUpdateOrder_Look),look(look),x(x),y(y){}
 void OnLateUpdate(CubismModel* model,const csmFloat32) override {look.UpdateParameters(model,x,y);}
};
}
namespace Lite2D {
void startRuntime(const std::string& resources) {
 if(started)return;shaderRoot=resources;
 options.LoggingLevel=CubismFramework::Option::LogLevel_Warning;
 options.LogFunction=[](const char* message){fprintf(stderr,"Cubism: %s\n",message);};
 options.LoadFileFunction=shaderFile;options.ReleaseBytesFunction=releaseFile;
 if(!CubismFramework::StartUp(&allocator,&options))throw Lite2D::LocalizedEngineError("error.engine_startup", "Cubism startup failed");
 CubismFramework::Initialize();started=true;
}
void stopRuntime(){if(started){CubismFramework::Dispose();CubismFramework::CleanUp();started=false;}}

class NativeHost::Impl : public CubismUserModel {
public:
 std::unique_ptr<CubismModelSettingJson> settings;
 std::filesystem::path directory;
 std::vector<GLuint> textures;
 std::map<std::string,std::vector<ACubismMotion*>> motions;
 std::map<std::string,ACubismMotion*> expressionMap;
 std::string idleGroup;
 bool interactionActive=false;
 std::map<std::string,std::vector<double>> motionWeights;
 std::mt19937 random{std::random_device{}()};
 int renderWidth=0,renderHeight=0;
 float lookX=0,lookY=0;
 ~Impl() override {
  _motionManager->StopAllMotions();_expressionManager->StopAllMotions();
  DeleteRenderer();
  for(auto& group:motions)for(auto* m:group.second)ACubismMotion::Delete(m);
  for(auto& e:expressionMap)ACubismMotion::Delete(e.second);
  if(!textures.empty())glDeleteTextures((GLsizei)textures.size(),textures.data());
  CubismOffscreenManager_OpenGLES2::ReleaseInstance();
  CubismRenderer::StaticRelease();
 }
 std::vector<unsigned char> asset(const char* name) {
  auto path=directory/name;
  return path.extension()==".json"?readJsonFile(path.string()):readFile(path.string());
 }
 bool has(const char* name){
  auto id=CubismFramework::GetIdManager()->GetId(name);
  for(int i=0;i<_model->GetParameterCount();++i)if(_model->GetParameterId(i)==id)return true;
  return false;
 }
 void load(const std::string& path,int width,int height) {
  glewExperimental=GL_TRUE;
  if(glewInit()!=GLEW_OK)throw Lite2D::LocalizedEngineError("error.engine_glew", "GLEW initialization failed");
  while(glGetError()!=GL_NO_ERROR){}
  directory=std::filesystem::path(path).parent_path();auto json=readJsonFile(path);
  settings=std::make_unique<CubismModelSettingJson>(json.data(),(int)json.size());
  if(!settings->IsValid())throw Lite2D::LocalizedEngineError("error.engine_parser", "Model JSON is unsupported by Cubism parser");
  auto moc=asset(settings->GetModelFileName());LoadModel(moc.data(),(int)moc.size(),true);
  if(!_model)throw Lite2D::LocalizedEngineError("error.engine_moc", "Invalid or unsupported moc3");
  auto optional=[&](const char* name,auto load){
   if(name&&*name){try {auto b=asset(name);load(b);}catch(const std::exception& e){fprintf(stderr,"Optional asset skipped: %s\n",e.what());}}
  };
  optional(settings->GetPhysicsFileName(),[&](auto& b){LoadPhysics(b.data(),(int)b.size());});
  optional(settings->GetPoseFileName(),[&](auto& b){LoadPose(b.data(),(int)b.size());});
  csmVector<CubismIdHandle> blinkIds,lipSyncIds;
  for(int i=0;i<settings->GetEyeBlinkParameterCount();++i)blinkIds.PushBack(settings->GetEyeBlinkParameterId(i));
  for(int g=0;g<settings->GetMotionGroupCount();++g) {
   std::string group=settings->GetMotionGroupName(g);
   auto& entries=motions[group];
   for(int i=0;i<settings->GetMotionCount(group.c_str());++i){
    ACubismMotion* motion=nullptr;
    optional(settings->GetMotionFileName(group.c_str(),i),[&](auto& b){
     motion=LoadMotion(b.data(),(int)b.size(),nullptr,nullptr,nullptr,settings.get(),group.c_str(),i);
     if(motion){motion->SetLoop(false);static_cast<CubismMotion*>(motion)->SetEffectIds(blinkIds,lipSyncIds);}
    });entries.push_back(motion);
   }
   if(group=="Idle"||group=="idle")idleGroup=group;
  }
  for(int i=0;i<settings->GetExpressionCount();++i) {
   optional(settings->GetExpressionFileName(i),[&](auto& b){
    auto* expression=LoadExpression(b.data(),(int)b.size(),settings->GetExpressionName(i));
    if(expression)expressionMap[settings->GetExpressionName(i)]=expression;
   });
  }
  _eyeBlink=CubismEyeBlink::Create(settings.get());
  _breath=CubismBreath::Create();
  csmVector<CubismBreath::BreathParameterData> breath;
  if(has("ParamBreath"))breath.PushBack(CubismBreath::BreathParameterData(CubismFramework::GetIdManager()->GetId("ParamBreath"),0.5f,0.5f,3.2f,1.f));
  _breath->SetParameters(breath);
  _look=CubismLook::Create();csmVector<CubismLook::LookParameterData> look;
  struct Target {const char* name;float x,y,xy;};
  for(auto p:{Target{"ParamAngleX",30,0,0},Target{"ParamAngleY",0,30,0},Target{"ParamAngleZ",0,0,-20},Target{"ParamBodyAngleX",10,0,0},Target{"ParamEyeBallX",1,0,0},Target{"ParamEyeBallY",0,1,0}})
   if(has(p.name))look.PushBack(CubismLook::LookParameterData(CubismFramework::GetIdManager()->GetId(p.name),p.x,p.y,p.xy));
  _look->SetParameters(look);
  // Caller already applies time-based look smoothing; avoid a second drag filter.
  _updateScheduler.AddUpdatableList(CSM_NEW CubismExpressionUpdater(*_expressionManager));
  _updateScheduler.AddUpdatableList(CSM_NEW DirectLookUpdater(*_look,lookX,lookY));
  _updateScheduler.AddUpdatableList(CSM_NEW CubismBreathUpdater(*_breath));
  if(_physics)_updateScheduler.AddUpdatableList(CSM_NEW CubismPhysicsUpdater(*_physics));
  if(_pose)_updateScheduler.AddUpdatableList(CSM_NEW CubismPoseUpdater(*_pose));
  csmMap<csmString,csmFloat32> layout;settings->GetLayoutMap(layout);_modelMatrix->SetupFromLayout(layout);
  CreateRenderer(width,height);renderWidth=width;renderHeight=height;
  for(int i=0;i<settings->GetTextureCount();++i) {
   auto bytes=asset(settings->GetTextureFileName(i));int w,h,n;
   auto* pixels=stbi_load_from_memory(bytes.data(),(int)bytes.size(),&w,&h,&n,4);
   if(!pixels)throw Lite2D::LocalizedEngineError("error.engine_texture", "Cannot decode model texture");
   GLuint tex;glGenTextures(1,&tex);textures.push_back(tex);glBindTexture(GL_TEXTURE_2D,tex);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);glGenerateMipmap(GL_TEXTURE_2D);stbi_image_free(pixels);
   GetRenderer<CubismRenderer_OpenGLES2>()->BindTexture(i,tex);
  }
  GetRenderer<CubismRenderer_OpenGLES2>()->IsPremultipliedAlpha(false);_model->SaveParameters();
 }
 bool play(const std::string& group,int index){
  auto found=motions.find(group);
  if(found==motions.end()||index<0||index>=found->second.size()||!found->second[index])return false;
  interactionActive=false;
  _motionManager->SetReservePriority(3);_motionManager->StartMotionPriority(found->second[index],false,3);return true;
 }
 bool playRandom(const std::string& group) {
  auto found=motions.find(group);if(found==motions.end())return false;
  auto weights=motionWeights.find(group);
  std::vector<double> values;
  double maximum=0;
  for(size_t i=0;i<found->second.size();++i){
   double weight=weights!=motionWeights.end()&&i<weights->second.size()?weights->second[i]:1;
   if(!found->second[i]||!std::isfinite(weight)||weight<0)weight=0;
   values.push_back(weight);maximum=std::max(maximum,weight);
  }
  if(maximum==0)return false;
  // Normalize first so large, finite user weights cannot overflow the sum.
  for(auto& weight:values)weight/=maximum;
  std::discrete_distribution<int> choose(values.begin(),values.end());
  return play(group,choose(random));
 }
 bool playIdle(){return playRandom(idleGroup);}
 bool interactionPlaying() const {return interactionActive&&!_motionManager->IsFinished();}
 bool playInteraction(const std::string& group) {
  if(interactionPlaying())return false;
  if(!playRandom(group))return false;
  interactionActive=true;return true;
 }
 void idle(const std::string& group){
  interactionActive=false;
  idleGroup=group;
  if(!playIdle())_motionManager->StopAllMotions();
 }
 void update(double dt,float x,float y) {
  _model->LoadParameters();
  if(_motionManager->IsFinished())interactionActive=false;
  if(dt>0&&_motionManager->IsFinished()&&!idleGroup.empty())playIdle();
  bool moved=_motionManager->UpdateMotion(_model,(float)dt);_model->SaveParameters();
  if(!moved&&_eyeBlink)_eyeBlink->UpdateParameters(_model,(float)dt);
  lookX=x;lookY=y;
  _updateScheduler.OnLateUpdate(_model,(float)dt);_model->Update();
 }
 void render(int width,int height,float scale) {
  if(width!=renderWidth||height!=renderHeight){SetRenderTargetSize(width,height);renderWidth=width;renderHeight=height;}
  float aspect=(float)width/height;CubismMatrix44 projection;
  if(_model->GetCanvasWidth()>1.f&&width<height){_modelMatrix->SetWidth(2.f);projection.Scale(1,aspect);}
  else projection.Scale(1/aspect,1);
  projection.ScaleRelative(scale,scale);projection.MultiplyByMatrix(_modelMatrix);
  auto* pool=CubismOffscreenManager_OpenGLES2::GetInstance();pool->BeginFrameProcess();
  auto* renderer=GetRenderer<CubismRenderer_OpenGLES2>();renderer->SetMvpMatrix(&projection);renderer->DrawModel();
  pool->EndFrameProcess();pool->ReleaseStaleRenderTextures();
 }
 bool expression(const std::string& name){
  if(name.empty()){_expressionManager->StopAllMotions();return true;}
  auto it=expressionMap.find(name);if(it==expressionMap.end())return false;
  _expressionManager->StartMotion(it->second,false);return true;
 }
};
NativeHost::NativeHost():impl(std::make_unique<Impl>()){}
NativeHost::~NativeHost()=default;
void NativeHost::load(const std::string& p,int w,int h){impl->load(p,w,h);}
void NativeHost::update(double dt,float x,float y){impl->update(dt,x,y);}
void NativeHost::render(int w,int h,float s){impl->render(w,h,s);}
bool NativeHost::play(const std::string& g,int i){return impl->play(g,i);}
bool NativeHost::playInteraction(const std::string& g){return impl->playInteraction(g);}
bool NativeHost::interactionPlaying() const{return impl->interactionPlaying();}
bool NativeHost::expression(const std::string& n){return impl->expression(n);}
void NativeHost::weights(const std::map<std::string,std::vector<double>>& w){impl->motionWeights=w;}
void NativeHost::idle(const std::string& g){impl->idle(g);}
std::map<std::string,int> NativeHost::groups() const{std::map<std::string,int> result;for(auto& g:impl->motions)result[g.first]=(int)g.second.size();return result;}
std::vector<std::string> NativeHost::expressions() const{std::vector<std::string> result;for(auto& e:impl->expressionMap)result.push_back(e.first);return result;}
float NativeHost::canvasAspect() const{return impl->GetModel()->GetCanvasWidth()/impl->GetModel()->GetCanvasHeight();}
}

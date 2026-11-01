// This file is Lite2D's host adapter, not the proprietary Cubism 2 runtime.
// It runs in an isolated JavaScriptCore VM per model, with no DOM or network.
var window=globalThis, navigator={userAgent:'Lite2D macOS JavaScriptCore'};
var console={log:function(){__log(Array.from(arguments).join(' '));},warn:function(){},error:function(){__log(Array.from(arguments).join(' '));}};
var gl=Object.assign({canvas:{width:1,height:1}},glConstants);
['activeTexture','bindBuffer','bindTexture','bindFramebuffer','bindRenderbuffer',
 'blendEquationSeparate','blendFuncSeparate','enable','disable','frontFace','cullFace',
 'enableVertexAttribArray','disableVertexAttribArray','vertexAttribPointer',
 'bufferData','drawElements','useProgram','compileShader','attachShader','linkProgram',
 'uniform1i','uniform4f','uniformMatrix4fv','texParameteri','texImage2D',
 'renderbufferStorage','framebufferRenderbuffer','framebufferTexture2D',
 'viewport','clearColor','clear','colorMask','flush','shaderSource','getExtension',
 'getAttribLocation','getUniformLocation','getShaderParameter','getProgramParameter',
 'getShaderInfoLog','getProgramInfoLog','getParameter','getError',
 'createBuffer','createTexture','createFramebuffer','createRenderbuffer','createShader','createProgram',
 'deleteBuffer','deleteTexture','deleteFramebuffer','deleteRenderbuffer','deleteShader','deleteProgram']
.forEach(function(name){gl[name]=function(){return __gl(name,Array.from(arguments));};});
var motions={}, queue, idleGroup='', blinkTime=0;
function registerMotion(group,index,settings){
    if(!motions[group]) motions[group]=[];
    var motion=Live2DMotion.loadMotion(motionBytes);
    motionBytes=null;
    if(settings.fade_in!=null)motion.setFadeIn(settings.fade_in);
    if(settings.fade_out!=null)motion.setFadeOut(settings.fade_out);
    motions[group][index]=motion;
}
function initializeLegacy(){
    queue=new MotionQueueManager();
    idleGroup=motions.idle?'idle':motions.Idle?'Idle':'';
}
function playLegacy(group,index){
    if(!motions[group]||!motions[group][index])return false;
    queue.startMotion(motions[group][index],false);return true;
}
function stepLegacy(time,x,y){
    UtSystem.setUserTimeMSec(time*1000);
    model.loadParam();
    if(queue.isFinished()&&idleGroup)playLegacy(idleGroup,0);
    queue.updateParam(model);
    model.saveParam();
    // The legacy SDK creates harmless virtual parameters for IDs absent from
    // the model. Such IDs do not affect drawable geometry.
    function set(id,value){if(model.getParamIndex(id)>=0)model.setParamFloat(id,value);}
    function add(id,value){if(model.getParamIndex(id)>=0)model.addToParamFloat(id,value);}
    add('PARAM_ANGLE_X',x*30);add('PARAM_ANGLE_Y',y*30);
    add('PARAM_ANGLE_Z',-x*y*20);add('PARAM_BODY_ANGLE_X',x*10);
    set('PARAM_EYE_BALL_X',x);set('PARAM_EYE_BALL_Y',y);
    set('PARAM_BREATH',(Math.sin(time*2)+1)*0.5);
    var phase=time%4.3, openness=phase<0.18?Math.abs(phase-0.09)/0.09:1;
    set('PARAM_EYE_L_OPEN',openness);set('PARAM_EYE_R_OPEN',openness);
    model.update();
}
var matrix=new Float32Array(16);
function drawLegacy(width,height,scale){
    gl.canvas.width=gl.drawingBufferWidth=width;gl.canvas.height=gl.drawingBufferHeight=height;
    var w=model.getCanvasWidth(),h=model.getCanvasHeight();
    var s=Math.min(width/w,height/h)*0.96*scale;
    matrix.fill(0);matrix[0]=2*s/width;matrix[5]=-2*s/height;matrix[10]=matrix[15]=1;
    matrix[12]=-w*s/width;matrix[13]=h*s/height;
    model.setMatrix(matrix);model.draw();
}

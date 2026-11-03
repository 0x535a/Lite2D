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
// Preserve the SDK's OpenGL command order, but cross the ObjC/JSC boundary once
// per batch rather than once per GL argument. Readbacks/creation flush first.
var glCommands=[], glBuffers=[];
function flushGLCommands(){
    if(!glCommands.length)return;
    var commands=new Float64Array(glCommands), buffers=glBuffers;
    glCommands=[];glBuffers=[];
    __glBatch(commands,buffers);
}
var batchNames=['activeTexture','bindBuffer','bindTexture','bindFramebuffer','bindRenderbuffer',
 'blendEquationSeparate','blendFuncSeparate','enable','disable','frontFace','cullFace',
 'enableVertexAttribArray','disableVertexAttribArray','vertexAttribPointer','drawElements',
 'useProgram','uniform1i','uniform4f','texParameteri','viewport','clearColor','clear','colorMask'];
Object.keys(gl).forEach(function(name){
    if(typeof gl[name]!=='function')return;
    var immediate=gl[name], opcode=batchNames.indexOf(name);
    if(opcode>=0)gl[name]=function(){
        glCommands.push(opcode);
        for(var i=0;i<arguments.length;i++)glCommands.push(Number(arguments[i]||0));
    };
    else gl[name]=function(){flushGLCommands();return immediate.apply(gl,arguments);};
});
gl.bufferData=function(target,data,usage){
    if(typeof data==='number'){glCommands.push(24,target,data,usage);return;}
    var snapshot=new Uint8Array(data.buffer,data.byteOffset,data.byteLength).slice();
    glCommands.push(23,target,usage,glBuffers.length);glBuffers.push(snapshot);
};
gl.uniformMatrix4fv=function(location,transpose,data){
    glCommands.push(25,location,Number(transpose),data.length/16);
    for(var i=0;i<data.length;i++)glCommands.push(data[i]);
};
var motions={}, motionWeights={}, queue, idleGroup='', blinkTime=0;
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
function playLegacyIdle(){
    var entries=motions[idleGroup]||[], weights=motionWeights[idleGroup]||[];
    var values=[], maximum=0;
    for(var i=0;i<entries.length;i++){
        var weight=weights[i]==null?1:Number(weights[i]);
        if(!entries[i]||!isFinite(weight)||weight<0)weight=0;
        values.push(weight);maximum=Math.max(maximum,weight);
    }
    if(!maximum)return false;
    var total=0;
    for(var i=0;i<values.length;i++){values[i]/=maximum;total+=values[i];}
    var draw=Math.random()*total, last=-1;
    for(var i=0;i<values.length;i++){
        if(!values[i])continue;
        last=i;draw-=values[i];
        if(draw<0)return playLegacy(idleGroup,i);
    }
    return last>=0&&playLegacy(idleGroup,last);
}
function setLegacyIdle(group){
    idleGroup=group;
    if(!playLegacyIdle())queue.stopAllMotions();
}
function stepLegacy(time,x,y){
    UtSystem.setUserTimeMSec(time*1000);
    model.loadParam();
    if(queue.isFinished()&&idleGroup)playLegacyIdle();
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
    model.setMatrix(matrix);model.draw();flushGLCommands();
}

import Foundation
import JavaScriptCore

// Real Cubism 2 motions must retain their coordinated eyelid and smile-eye shapes.
@main struct LegacyEyeBlinkTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error?.toString() ?? "JS error") }
        func evaluate(_ script: String) { context.evaluateScript(script) }
        evaluate("var window=globalThis,navigator={userAgent:'Lite2D'},console={log:function(){}};")
        evaluate(
            try String(
                contentsOf: root.appendingPathComponent("Resources/LegacyRuntime/legacy-core.js"),
                encoding: .utf8))
        evaluate(
            "var glConstants={},__gl=function(){return 0;},__glBatch=function(){},__log=function(){};"
        )
        evaluate(
            try String(
                contentsOf: root.appendingPathComponent("Resources/legacy-host.js"), encoding: .utf8
            ))
        let directory = root.appendingPathComponent(".local/models/legacy-a")
        let json =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("model.json")))
            as! [String: Any]
        let bytes = try Data(contentsOf: directory.appendingPathComponent(json["model"] as! String))
        context.setObject(
            bytes.map { NSNumber(value: $0) }, forKeyedSubscript: "inputBytes" as NSString)
        evaluate(
            "Live2D.setGL(gl);var model=Live2DModelWebGL.loadModel(new Uint8Array(inputBytes).buffer);model.saveParam();"
        )
        for group in ["idle", "tap"] {
            for (index, motion) in (json["motions"] as! [String: [[String: Any]]])[group]!
                .enumerated()
            {
                let data = try Data(
                    contentsOf: directory.appendingPathComponent(motion["file"] as! String))
                context.setObject(
                    data.map { NSNumber(value: $0) }, forKeyedSubscript: "inputBytes" as NSString)
                context.setObject(motion, forKeyedSubscript: "motionSettings" as NSString)
                evaluate(
                    "var motionBytes=new Uint8Array(inputBytes).buffer;registerMotion('\(group)',\(index),motionSettings);"
                )
            }
        }
        evaluate(
            """
            function assert(value,message){if(!value)throw Error(message);}
            initializeLegacy(); idleGroup=''; var rawUpdate=queue.updateParam, sample={}, time=0, report=[];
            queue.updateParam=function(m){
             var moved=rawUpdate.call(this,m);
             sample={moved:moved,left:m.getParamFloat('PARAM_EYE_L_OPEN'),right:m.getParamFloat('PARAM_EYE_R_OPEN')};
             return moved;
            };
            ['idle','tap'].forEach(function(group){motions[group].forEach(function(_,index){
             queue.stopAllMotions(); UtSystem.setUserTimeMSec(time*1000); playLegacy(group,index);
             var testedFrames=0, closedFrames=0;
             for(var i=0;i<300;i++){
              time+=1/30;stepLegacy(time,0,0);
              if(!sample.moved)continue;
              testedFrames++;
              var left=model.getParamFloat('PARAM_EYE_L_OPEN'),right=model.getParamFloat('PARAM_EYE_R_OPEN');
              assert(Math.abs(sample.left-left)<0.00001&&Math.abs(sample.right-right)<0.00001,
                     group+'['+index+'] authored eyelid values were overwritten');
              if(sample.left<0.5||sample.right<0.5)closedFrames++;
             }
             assert(testedFrames>0&&closedFrames>0,group+'['+index+'] exercises authored eye closure');
             report.push({group:group,index:index,testedFrames:testedFrames,closedFrames:closedFrames});
            });});
            queue.stopAllMotions(); idleGroup='';
            stepLegacy(86.09,0,0);
            assert(!sample.moved,'fallback frame has no motion');
            assert(model.getParamFloat('PARAM_EYE_L_OPEN')<0.001&&model.getParamFloat('PARAM_EYE_R_OPEN')<0.001,
                   'automatic blink still closes both eyes without motions');
            stepLegacy(86.5,0,0);
            assert(model.getParamFloat('PARAM_EYE_L_OPEN')===1&&model.getParamFloat('PARAM_EYE_R_OPEN')===1,
                   'automatic blink reopens both eyes without motions');
            """)
        print(
            "PASS: authored eye parameters preserved in all 3 idle and 2 tap motions; motion-free blinking still works"
        )
    }
}

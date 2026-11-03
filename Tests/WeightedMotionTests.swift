import Foundation
import JavaScriptCore

// Exercise the real Cubism 2 queue and host adapter without a GL window.
@main struct WeightedMotionTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let context = JSContext()!
        var exceptions: [String] = []
        context.exceptionHandler = { _, error in exceptions.append(error?.toString() ?? "Unknown JS error") }
        func evaluate(_ script: String) {
            context.evaluateScript(script)
            precondition(exceptions.isEmpty, exceptions.joined(separator: "\n"))
        }
        evaluate("var window=globalThis, navigator={userAgent:'Lite2D'}, console={log:function(){}};")
        evaluate(try String(contentsOf: root.appendingPathComponent("Resources/LegacyRuntime/legacy-core.js"), encoding: .utf8))
        evaluate("var glConstants={}, __gl=function(){return 0;}, __glBatch=function(){}, __log=function(){};")
        evaluate(try String(contentsOf: root.appendingPathComponent("Resources/legacy-host.js"), encoding: .utf8))
        let entry = root.appendingPathComponent(".local/models/legacy-a/model.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: entry)) as! [String: Any]
        let directory = entry.deletingLastPathComponent()
        let modelBytes = try Data(contentsOf: directory.appendingPathComponent(json["model"] as! String))
        context.setObject(modelBytes.map { NSNumber(value: $0) }, forKeyedSubscript: "inputBytes" as NSString)
        evaluate("Live2D.setGL(gl); var model=Live2DModelWebGL.loadModel(new Uint8Array(inputBytes).buffer); model.saveParam();")
        let idle = (json["motions"] as! [String: [[String: Any]]])["idle"]!
        for (index, motion) in idle.enumerated() {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(motion["file"] as! String))
            context.setObject(bytes.map { NSNumber(value: $0) }, forKeyedSubscript: "inputBytes" as NSString)
            context.setObject(motion, forKeyedSubscript: "motionSettings" as NSString)
            evaluate("var motionBytes=new Uint8Array(inputBytes).buffer; registerMotion('idle',\(index),motionSettings);")
        }
        evaluate("""
            function assert(value,message){if(!value)throw Error(message);}
            UtSystem.setUserTimeMSec(0); initializeLegacy();
            var history=[], originalPlay=playLegacy;
            playLegacy=function(group,index){history.push(index);return originalPlay(group,index);};
            motionWeights={idle:[4,1,1]};
            Math.random=function(){return 0;}; assert(playLegacyIdle(),'first starts');
            assert(playLegacyIdle()&&history.join(',')==='0,0','consecutive repeats allowed');
            Math.random=function(){return 0.7;}; playLegacyIdle(); assert(history.pop()===1,'weighted second interval');
            Math.random=function(){return 0.95;}; playLegacyIdle(); assert(history.pop()===2,'weighted third interval');
            motionWeights={idle:[0,1,0]};
            Math.random=function(){return 0;}; playLegacyIdle(); assert(history.pop()===1,'zero weights excluded');
            motionWeights={idle:[0,0,0]};
            assert(!playLegacyIdle(),'all zero selects nothing');
            assert(playLegacy('idle',2),'zero weight still plays manually');
            setLegacyIdle(''); assert(queue.isFinished(),'none stops current playback');
            motionWeights={idle:[1,0,0]}; setLegacyIdle('idle');
            playLegacy('idle',1); history=[];
            for(var i=0;i<600;i++)stepLegacy(i/30,0,0);
            assert(history.length>1&&history.every(function(i){return i===0;}),'manual action completes, then idle repeats');
            motions.idle[1]=null; motionWeights={idle:[0,100,0]};
            assert(!playLegacyIdle(),'unloaded action cannot be selected');
            motionWeights={idle:[Number.MAX_VALUE,Number.MAX_VALUE,Number.MAX_VALUE]};
            assert(playLegacyIdle(),'large weights stay finite');
            motions.custom=motions.idle.slice(); motionWeights.custom=[0,0,1];
            assert(playLegacyInteraction('custom'),'arbitrary interaction group starts');
            assert(history.pop()===2,'interaction respects zero weights');
            assert(isLegacyInteractionPlaying(),'interaction marked active immediately');
            assert(!playLegacyInteraction('idle'),'repeated clicks cannot interrupt interaction');
            history=[];
            for(var i=600;i<1800;i++)stepLegacy(i/30,0,0);
            assert(!isLegacyInteractionPlaying()&&history.length>1,'interaction completes and idle resumes');
            assert(playLegacyInteraction('idle'),'idle may also be selected for interaction');
            playLegacy('idle',0);
            assert(!isLegacyInteractionPlaying(),'manual action clears interaction lock');
            motionWeights.custom=[0,0,0];
            assert(!playLegacyInteraction('custom'),'all zero interaction does nothing');
            assert(!playLegacyInteraction('missing'),'missing group does nothing');
            """)
        print("Weighted playback passed: intervals, repeats, zero weights, manual completion, missing motions, large weights")
    }
}

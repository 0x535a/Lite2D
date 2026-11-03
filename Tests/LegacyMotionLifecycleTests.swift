import Foundation
import JavaScriptCore

// Exercise complete transitions with the real Cubism 2 queue, including controls
// that idle never writes. No window, OS events, or private SDK fields are used.
@main struct LegacyMotionLifecycleTests {
    static func main() {
        do {
            try run()
            print(
                "PASS: tap-to-idle parameter/part restoration, fade ownership, interruption, no idle, repeated/custom actions and preserved external state"
            )
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let context = JSContext()!
        var exceptions: [String] = []
        context.exceptionHandler = { _, error in exceptions.append(error?.toString() ?? "JS error")
        }
        func evaluate(_ script: String) throws {
            exceptions = []
            context.evaluateScript(script)
            if !exceptions.isEmpty {
                throw NSError(
                    domain: "LegacyMotionLifecycle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: exceptions.joined(separator: "\n")])
            }
        }
        try evaluate(
            "var window=globalThis,navigator={userAgent:'Lite2D'},console={log:function(){}};")
        try evaluate(
            try String(
                contentsOf: root.appendingPathComponent("Resources/LegacyRuntime/legacy-core.js"),
                encoding: .utf8))
        try evaluate(
            "var glConstants={},__gl=function(){return 0;},__glBatch=function(){},__log=function(){};"
        )
        try evaluate(
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
        try evaluate(
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
                try evaluate(
                    "var motionBytes=new Uint8Array(inputBytes).buffer;registerMotion('\(group)',\(index),motionSettings);"
                )
            }
        }
        try evaluate(
            """
            function assert(value,message){if(!value)throw Error(message);}
            function near(a,b){return Math.abs(a-b)<0.00001;}
            initializeLegacy(); var time=0;
            function advance(frames){for(var i=0;i<frames;i++){time+=1/30;stepLegacy(time,0,0);}}
            function selectIdle(index){
                motionWeights.idle=[0,0,0];motionWeights.idle[index]=1;
                setLegacyIdle('idle');advance(180);
            }
            function checkRestored(label){
                assert(!isLegacyInteractionPlaying(),label+': interaction finished');
                assert(near(model.getParamFloat('PARAM_EYEDEFORM'),0),label+': eye deform returned to baseline');
                assert(near(model.getParamFloat('PARAM_L'),0),label+': other action-only parameter returned to baseline');
            }
            // This is the reported sequence: tap_2 fades out, then idle keeps
            // moving while its missing eye-deform channel must return to zero.
            selectIdle(0);motionWeights.tap=[0,1];
            assert(playLegacyInteraction('tap'),'tap_2 starts');advance(90);
            assert(model.getParamFloat('PARAM_EYEDEFORM')>0.5,'active tap deform remains visible');
            advance(210);checkRestored('tap_2 -> idle_0');
            var angle=model.getParamFloat('PARAM_ANGLE_Y');advance(30);
            assert(!near(angle,model.getParamFloat('PARAM_ANGLE_Y')),'idle continues animating after restoration');
            checkRestored('idle remains clean');
            // Every idle choice and both tap choices, including consecutive clicks.
            for(var idle=0;idle<3;idle++)for(var tap=0;tap<2;tap++){
                selectIdle(idle);motionWeights.tap=[0,0];motionWeights.tap[tap]=1;
                assert(playLegacyInteraction('tap'),'each tap starts');advance(300);
                checkRestored('tap_'+tap+' -> idle_'+idle);
            }
            // Metadata must follow the motion object, not a hard-coded tap group.
            motions.custom=[motions.tap[1]];motionWeights.custom=[1];selectIdle(0);
            assert(playLegacyInteraction('custom'),'custom group starts');advance(300);checkRestored('custom group');
            // A manual change leaves the outgoing action alive through its fade.
            motionWeights.tap=[0,1];assert(playLegacyInteraction('tap'),'interruptible tap starts');advance(90);
            playLegacy('idle',0);advance(1);
            assert(model.getParamFloat('PARAM_EYEDEFORM')>0.1,'outgoing fade still owns its parameter');
            advance(120);checkRestored('manual interruption');
            // No loop group must also release the finished action's channels.
            setLegacyIdle('');advance(1);assert(playLegacyInteraction('tap'),'tap without idle starts');
            advance(300);checkRestored('no idle');
            // Register a synthetic action through the same loader. It writes a
            // nonzero-default parameter and a part opacity that idle omits.
            model.setParamFloat('PARAM_HAIR_BACK',0.375);model.saveParam();
            var baselinePart=model.getPartsOpacity('PARTS_EYE_DEFORM');
            var text=['# Live2D Animator Motion Data','$fps=30','$fadein=0','$fadeout=0','PARAM_HAIR_BACK=1,1,1','VISIBLE:PARTS_EYE_DEFORM=0,0,0',''].join(String.fromCharCode(10)+String.fromCharCode(10));
            var bytes=new Uint8Array(text.length);for(var i=0;i<text.length;i++)bytes[i]=text.charCodeAt(i);
            motionBytes=bytes.buffer;registerMotion('synthetic',0,{fade_in:0,fade_out:0});
            model.setParamFloat('PARAM_EXTERNAL_STATE',0.625);model.saveParam();
            selectIdle(0);assert(playLegacyInteraction('synthetic'),'synthetic action starts');advance(2);
            assert(near(model.getParamFloat('PARAM_HAIR_BACK'),1),'synthetic parameter applies');
            // Simulate a part-opacity driver during the active action; the SDK
            // variant used here applies VISIBLE curves through parameters.
            model.setPartsOpacity('PARTS_EYE_DEFORM',0);advance(1);
            assert(near(model.getPartsOpacity('PARTS_EYE_DEFORM'),0),'active action retains its part state');
            advance(150);
            assert(near(model.getParamFloat('PARAM_HAIR_BACK'),0.375),'nonzero baseline restored');
            assert(near(model.getPartsOpacity('PARTS_EYE_DEFORM'),baselinePart),'part opacity baseline restored');
            assert(near(model.getParamFloat('PARAM_EXTERNAL_STATE'),0.625),'non-motion state preserved');
            """)
    }
}

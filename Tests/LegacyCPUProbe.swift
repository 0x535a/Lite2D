import Foundation
import JavaScriptCore

// CPU-only compatibility probe, deliberately without AppKit, WebView or Pixi.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runtime = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/RimeLive2D/web/vendor/live2d.min.js")
let sdk = try String(contentsOf: runtime, encoding: .utf8)
for name in ["bilibili-22", "bilibili-33"] {
    let context = JSContext()!
    var exceptions: [String] = []
    context.exceptionHandler = { _, value in exceptions.append(value?.toString() ?? "Unknown exception") }
    context.evaluateScript("""
        var window=globalThis, navigator={userAgent:'Lite2D macOS JavaScriptCore'};
        var console={log:function(){},warn:function(){},error:function(){}};
        var gl=new Proxy({}, {get:function(target,key){
            if (/^[A-Z_0-9]+$/.test(key)) return 0;
            if (key==='getParameter') return function(){return 0;};
            if (key==='getExtension') return function(){return null;};
            if (/^create/.test(key)) return function(){return {};};
            return function(){};
        }});
        """)
    context.evaluateScript(sdk)
    let directory = root.appendingPathComponent(".local/models/\(name)")
    let json = try Data(contentsOf: directory.appendingPathComponent("model.json"))
    let settings = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    let data = try Data(contentsOf: directory.appendingPathComponent(settings["model"] as! String))
    let bytes = data.map { NSNumber(value: $0) }
    context.setObject(bytes, forKeyedSubscript: "inputBytes" as NSString)
    context.evaluateScript("Live2D.setGL(gl); var model=Live2DModelWebGL.loadModel(new Uint8Array(inputBytes).buffer); model.saveParam(); model.update();")
    guard exceptions.isEmpty else { fatalError("\(name): \(exceptions)") }
    let width = context.evaluateScript("model.getCanvasWidth()")!.toDouble()
    let height = context.evaluateScript("model.getCanvasHeight()")!.toDouble()
    let error = context.evaluateScript("Live2D.getError()")!.toInt32()
    let vertices = context.evaluateScript("model.getTransformedPoints(0).length")!.toInt32()
    precondition(width > 0 && height > 0 && vertices > 0 && error == 0)
    print("\(name): canvas=\(width)x\(height), first drawable coordinates=\(vertices), SDK error=\(error)")
}

import AppKit
import Darwin

final class BenchmarkRunner {
    let manager: ModelInstanceManager
    let output: URL
    let staticSeconds: Double
    let movingSeconds: Double
    let complete: (Int32) -> Void
    private var timer: Timer?
    private var start = 0.0
    private var initialCPU = 0.0
    private var previousCPU = 0.0
    private var previousTime = 0.0
    private var initialFrames: [UUID: UInt64] = [:]
    private var samples: [[String: Any]] = []
    private var staticFrames: [UUID: UInt64] = [:]

    init(manager: ModelInstanceManager, output: URL, staticSeconds: Double, movingSeconds: Double, complete: @escaping (Int32) -> Void) {
        self.manager = manager; self.output = output; self.staticSeconds = staticSeconds
        self.movingSeconds = movingSeconds; self.complete = complete
    }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func memory() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (info.resident_size, info.phys_footprint) : (0, 0)
    }
    func run() {
        guard manager.records.allSatisfy({ $0.controller?.view.loaded == true }) else {
            NSLog("BENCHMARK_FAILED: one or more descriptors have no loaded renderer")
            complete(1); return
        }
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { complete(1); return }
        // Exclude launch/texture decode/JIT warmup from steady-state measurements.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            start = ProcessInfo.processInfo.systemUptime; previousTime = start
            initialCPU = Self.cpuSeconds(); previousCPU = initialCPU
            guard manager.records.allSatisfy({ !$0.settings.isVisible || ($0.controller?.view.frames ?? 0) > 0 }) else {
                NSLog("BENCHMARK_FAILED: a visible model did not render during warmup")
                complete(1); return
            }
            for record in manager.records { initialFrames[record.settings.id] = record.controller?.view.frames ?? 0 }
            if let screen = NSScreen.main { SharedMouseTracker.shared.testPoint = NSPoint(x: screen.frame.midX, y: screen.frame.midY) }
            timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            RunLoop.main.add(timer!, forMode: .common)
            NSLog("BENCHMARK_STARTED instances=%d static=%.0f moving=%.0f", manager.records.count, staticSeconds, movingSeconds)
        }
    }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - start
        let phase = elapsed <= staticSeconds ? "stationary-target" : "moving-target"
        if elapsed > staticSeconds {
            if staticFrames.isEmpty { for record in manager.records { staticFrames[record.settings.id] = record.controller?.view.frames ?? 0 } }
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1280)
            let angle = elapsed * 1.7
            SharedMouseTracker.shared.testPoint = NSPoint(x: screen.midX + sin(angle) * screen.width * 0.65,
                                                        y: screen.midY + cos(angle * 0.73) * screen.height * 0.65)
        }
        let cpu = Self.cpuSeconds(), memory = Self.memory()
        let row: [String: Any] = ["elapsedSeconds": elapsed, "phase": phase,
                                  "cpuPercentOneCore100": (cpu - previousCPU) / (now - previousTime) * 100,
                                  "residentBytes": memory.resident, "physicalFootprintBytes": memory.footprint,
                                  "frames": manager.records.map { ["id": $0.settings.id.uuidString, "count": $0.controller?.view.frames ?? 0,
                                                                     "glError": $0.controller?.view.lastGLError ?? 0] }]
        samples.append(row); previousCPU = cpu; previousTime = now
        try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("samples.json"), options: .atomic)
        if elapsed >= staticSeconds + movingSeconds {
            timer?.invalidate(); timer = nil
            SharedMouseTracker.shared.testPoint = nil
            let frames = manager.records.map { record -> [String: Any] in
                let count = record.controller?.view.frames ?? 0
                return ["id": record.settings.id.uuidString, "name": record.settings.displayName,
                        "modelPath": record.settings.modelPath, "targetFPS": record.settings.targetFPS,
                        "frames": count - (initialFrames[record.settings.id] ?? 0),
                        "actualFPS": Double(count - (initialFrames[record.settings.id] ?? 0)) / elapsed,
                        "gpuTimingRequested": ProcessInfo.processInfo.environment["LITE2D_GPU_TIMING"] == "1",
                        "gpuTimingAvailable": record.controller?.view.bridge.gpuTimingAvailable ?? false,
                        "gpuMeasuredFrames": record.controller?.view.bridge.gpuMeasuredFrames ?? 0,
                        "gpuNanoseconds": record.controller?.view.bridge.gpuNanoseconds ?? 0,
                        "glError": record.controller?.view.lastGLError ?? 0]
            }
            let summary: [String: Any] = ["durationSeconds": elapsed, "staticSeconds": staticSeconds,
                "movingSeconds": movingSeconds, "instances": manager.records.count,
                "cpuSeconds": cpu - initialCPU, "meanCPUPercentOneCore100": (cpu - initialCPU) / elapsed * 100,
                "frames": frames, "samples": samples.count,
                "targetInput": "In-process shared target, stationary then 1 Hz moving trajectory; does not move OS cursor."]
            try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"), options: .atomic)
            NSLog("BENCHMARK_DONE instances=%d elapsed=%.1f cpu=%.1f", manager.records.count, elapsed, (cpu - initialCPU) / elapsed * 100)
            complete(frames.allSatisfy { ($0["glError"] as? UInt32) == 0 } ? 0 : 1)
        }
    }
}

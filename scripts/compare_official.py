#!/usr/bin/env python3
"""Compare official Minimum and AppKit with the same model, size and target FPS.

Run after the 0–4 baseline. The official sample is temporarily instrumented to
bound execution and report its own process metrics; pinned sources are restored.
Animation features still differ, so these observations do not imply a winner.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seconds", type=int, default=30)
args = parser.parse_args()
if args.seconds < 5:
    raise ValueError("Use at least five measured seconds after warmup")
out = root / ".local/verification/official-comparison"
out.mkdir(parents=True, exist_ok=True)
source_dir = root / "vendor/CubismNativeSamples/Samples/OpenGL/Demo/proj.mac.cmake/src"
main_path, define_path = source_dir / "mainMinimum.cpp", source_dir / "LAppDefine.cpp"
original_main, original_defines = main_path.read_bytes(), define_path.read_bytes()
header = r'''
#include <chrono>
#include <thread>
#include <cstdio>
#include <cstdlib>
#include <sys/resource.h>
#include <mach/mach.h>
static double probeCPU() {
    rusage usage; getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
        (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
}
static double probeStart = 0, probeCPUStart = 0, probeLastSample = 0;
static unsigned long long probeFrames = 0;
'''
before_swap = r'''
        const double probeNow = glfwGetTime();
        if (probeNow >= 4.0) {
            if (!probeStart) { probeStart = probeNow; probeCPUStart = probeCPU(); }
            ++probeFrames;
            const double elapsed = probeNow - probeStart;
            if (elapsed - probeLastSample >= 1.0) {
                probeLastSample = elapsed;
                task_vm_info_data_t vm = {};
                mach_msg_type_number_t n = sizeof(vm) / sizeof(integer_t);
                task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n);
                std::printf("OFFICIAL_SAMPLE {\"elapsed\":%.6f,\"cpuSeconds\":%.6f,\"residentBytes\":%llu,\"physicalFootprintBytes\":%llu,\"frames\":%llu,\"width\":%d,\"height\":%d,\"glError\":%u}\n",
                    elapsed, probeCPU() - probeCPUStart,
                    (unsigned long long)vm.resident_size, (unsigned long long)vm.phys_footprint,
                    probeFrames, width, height, glGetError());
                std::fflush(stdout);
            }
            if (elapsed >= std::atof(std::getenv("LITE2D_OFFICIAL_BENCH_SECONDS")))
                glfwSetWindowShouldClose(_window, true);
        }
'''
pace = r'''
        static auto probeDeadline = std::chrono::steady_clock::now();
        probeDeadline += std::chrono::nanoseconds(33333333);
        if (probeDeadline < std::chrono::steady_clock::now())
            probeDeadline = std::chrono::steady_clock::now();
        std::this_thread::sleep_until(probeDeadline);
'''
main = original_main.decode("utf-8-sig")
marker = "        // バッファの入れ替え\n        glfwSwapBuffers(_window);"
end_marker = "        glfwPollEvents();"
if marker not in main or end_marker not in main:
    raise RuntimeError("Pinned official sample changed; instrumentation requires review")
main = header + main.replace("glfwSwapInterval(1)", "glfwSwapInterval(0)")
main = main.replace(marker, before_swap + marker).replace(end_marker, end_marker + pace)
defines = original_defines.decode("utf-8-sig")
defines = defines.replace("RenderTargetWidth = 1900", "RenderTargetWidth = 360")
defines = defines.replace("RenderTargetHeight = 1000", "RenderTargetHeight = 480")
try:
    main_path.write_text(main)
    define_path.write_text(defines)
    with (out / "build.log").open("w") as log:
        subprocess.run(["cmake", "--build", str(root / "build/official-minimum"), "--parallel", "6"],
                       stdout=log, stderr=subprocess.STDOUT, check=True, cwd=root)
finally:
    main_path.write_bytes(original_main)
    define_path.write_bytes(original_defines)
with (out / "official.log").open("w") as log:
    subprocess.run([str(root / "build/official-minimum/bin/Demo/Demo")], cwd=root,
                   env=dict(os.environ, LITE2D_OFFICIAL_BENCH_SECONDS=str(args.seconds)),
                   stdout=log, stderr=subprocess.STDOUT, timeout=args.seconds+30, check=True)
samples = [json.loads(line.split("OFFICIAL_SAMPLE ", 1)[1]) for line in (out / "official.log").read_text().splitlines()
           if "OFFICIAL_SAMPLE " in line]
if not samples or any(row["glError"] for row in samples):
    raise RuntimeError("No valid official GPU samples")
if any((row["width"], row["height"]) != (720, 960) for row in samples):
    raise RuntimeError("Official backing size differs from the AppKit comparison")
(out / "official-samples.json").write_text(json.dumps(samples, indent=2) + "\n")
app_out = out / "appkit"
app_out.mkdir(exist_ok=True)
settings = app_out / "settings.json"
settings.write_text(json.dumps({"schemaVersion": 2, "instances": [{
    "displayName": "Hiyori comparison", "modelPath": str(root / "vendor/CubismNativeSamples/Samples/Resources/Hiyori/Hiyori.model3.json"),
    "windowFrame": {"x": 80, "y": 100, "width": 360, "height": 480},
    "targetFPS": 30, "trackingEnabled": False}]}, indent=2) + "\n")
with (out / "appkit.log").open("w") as log:
    subprocess.run([str(root / "dist/Lite2D.app/Contents/MacOS/Lite2D"), "--benchmark"], cwd=root,
                   env=dict(os.environ, LITE2D_SETTINGS_PATH=str(settings), LITE2D_BENCH_OUTPUT=str(app_out),
                            LITE2D_STATIC_SECONDS=str(args.seconds), LITE2D_MOVING_SECONDS="0"),
                   stdout=log, stderr=subprocess.STDOUT, timeout=args.seconds+30, check=True)
last = samples[-1]
official = dict(actualFPS=last["frames"]/last["elapsed"], meanCPUPercent=last["cpuSeconds"]/last["elapsed"]*100,
                residentMiB=sum(row["residentBytes"] for row in samples)/len(samples)/1048576,
                physicalFootprintMiB=sum(row["physicalFootprintBytes"] for row in samples)/len(samples)/1048576,
                durationSeconds=last["elapsed"])
report = {"model": "Hiyori", "windowPoints": [360, 480], "backingPixels": [720, 960], "targetFPS": 30,
          "official": official, "appkit": json.loads((app_out / "summary.json").read_text()),
          "limits": "Official Minimum animation feature set and opaque GLFW composition differ from AppKit transparent desktop composition; no superiority claim."}
(out / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))

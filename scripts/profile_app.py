#!/usr/bin/env python3
"""Collect process-local Instruments, leaks and VM evidence for three models.

Run after the baseline matrix to avoid profiler overhead contaminating it.
Profiler data is kept local; the app exits through its own bounded benchmark.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
out = root / ".local/verification/profiling" / time.strftime("run-%Y%m%d-%H%M%S")
out.mkdir(parents=True, exist_ok=True)
assets = [root / ".local/models/bilibili-22/model.json", root / ".local/models/bilibili-33/model.json",
          root / ".local/models/bilibili-22/model.json"]
instances = [dict(id=str(uuid.uuid4()), displayName=f"profile-{index}", modelPath=str(asset),
                  windowFrame=dict(x=60+index*380, y=100, width=360, height=480), targetFPS=30)
             for index, asset in enumerate(assets)]
settings = out / "settings.json"
settings.write_text(json.dumps(dict(schemaVersion=2, instances=instances), indent=2) + "\n")
env = dict(os.environ, LITE2D_SETTINGS_PATH=str(settings), LITE2D_BENCH_OUTPUT=str(out),
           LITE2D_STATIC_SECONDS="75", LITE2D_MOVING_SECONDS="15")
results = []
with (out / "app.log").open("w") as app_log:
    process = subprocess.Popen([str(root / "dist/Lite2D.app/Contents/MacOS/Lite2D"), "--benchmark"],
                               cwd=root, env=env, stdout=app_log, stderr=subprocess.STDOUT)
    (out / "pid.json").write_text(json.dumps({"pid": process.pid}) + "\n")
    try:
        # Wait on evidence of the live program's completed warmup.
        deadline = time.monotonic() + 20
        while not (out / "samples.json").exists():
            if process.poll() is not None:
                raise RuntimeError("Application exited before profiling warmup")
            if time.monotonic() > deadline:
                raise TimeoutError("Application did not produce warmup samples")
            time.sleep(0.5)
        for template in ["Time Profiler", "Allocations", "Leaks", "Power Profiler"]:
            label = template.lower().replace(" ", "-")
            trace = out / (label + ".trace")
            with (out / (label + ".log")).open("w") as log:
                command = ["xcrun", "xctrace", "record", "--template", template, "--attach", str(process.pid),
                           "--time-limit", "8s", "--output", str(trace)]
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=35)
            results.append({"tool": template, "exit": result.returncode, "traceExists": trace.exists()})
            if trace.exists():
                subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc",
                                "--output", str(out / (label + "-toc.xml"))], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=20)
        for name, command in [("leaks", ["leaks", str(process.pid)]),
                              ("vmmap", ["vmmap", "-summary", str(process.pid)]),
                              ("footprint", ["footprint", "-p", str(process.pid)])]:
            with (out / (name + ".txt")).open("w") as log:
                try:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=20)
                    results.append({"tool": name, "exit": result.returncode})
                except subprocess.TimeoutExpired:
                    results.append({"tool": name, "error": "timeout"})
        result = process.wait(timeout=110)
        results.append({"tool": "app", "exit": result})
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
(out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps({"directory": str(out), "results": results}, indent=2))

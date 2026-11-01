#!/usr/bin/env python3
"""Bounded Instruments launch recordings, with isolated targets and cleanup.

Attaching Allocations after a JSCore VM has started stalls this local macOS /
Instruments combination. Launch each template on a fresh process instead; check
that the app actually completes, rather than trusting xctrace's exit alone.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("LITE2D_APP_PATH", str(ROOT / "dist/Lite2D.app/Contents/MacOS/Lite2D")))
OUT = ROOT / ".local/verification/profiling" / time.strftime("launch-%Y%m%d-%H%M%S")
OUT.mkdir(parents=True, exist_ok=True)
assets = [ROOT / ".local/models/bilibili-22/model.json", ROOT / ".local/models/bilibili-33/model.json",
          ROOT / ".local/models/bilibili-22/model.json", ROOT / ".local/models/bilibili-33/model.json"]


def test_processes():
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,stat=,command="], capture_output=True, text=True, check=True)
    found = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        pid, parent, state, command = parts
        if command.startswith(str(ROOT) + "/") and command.endswith("/Lite2D.app/Contents/MacOS/Lite2D --benchmark"):
            found[int(pid)] = dict(parent=int(parent), state=state, command=command)
    return found


def settings_for(count, destination):
    descriptors = [dict(id=str(uuid.uuid4()), displayName=f"profile-{index+1}", modelPath=str(assets[index]),
                        windowFrame=dict(x=80+index*380, y=100, width=360, height=480), targetFPS=30)
                   for index in range(count)]
    path = destination / "settings.json"
    path.write_text(json.dumps(dict(schemaVersion=2, instances=descriptors), indent=2) + "\n")
    return path


def record(template, count, label):
    directory = OUT / label
    directory.mkdir()
    settings = settings_for(count, directory)
    trace = directory / "recording.trace"
    command = ["xcrun", "xctrace", "record", "--template", template, "--time-limit", "24s",
               "--output", str(trace), "--target-stdout", str(directory / "app.log")]
    for key, value in dict(LITE2D_SETTINGS_PATH=str(settings), LITE2D_BENCH_OUTPUT=str(directory),
                           LITE2D_STATIC_SECONDS="10", LITE2D_MOVING_SECONDS="0").items():
        command += ["--env", key + "=" + value]
    command += ["--launch", "--", str(APP), "--benchmark"]
    before = test_processes()
    result = {"template": template, "instances": count, "directory": str(directory)}
    try:
        with (directory / "record.log").open("w") as log:
            process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=45)
        result["xctraceExit"] = process.returncode
        if trace.exists():
            subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output", str(directory / "toc.xml")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        if (directory / "toc.xml").exists():
            tree = ET.parse(directory / "toc.xml")
            result["target"] = [entry.attrib for entry in tree.findall("./run/info/target/process")]
            result["schemas"] = [entry.get("schema") for entry in tree.iter("table")]
        summary = directory / "summary.json"
        result["appCompleted"] = summary.exists()
        if summary.exists():
            data = json.loads(summary.read_text())
            result["actualFPS"] = [frame["actualFPS"] for frame in data["frames"]]
            result["glErrorCounts"] = [frame["glErrorCount"] for frame in data["frames"]]
    except subprocess.TimeoutExpired as error:
        result["error"] = str(error)
    finally:
        # xctrace leaves an orphaned, stopped launch placeholder on this host.
        # Clean only new, project-local benchmark processes from this recording.
        cleaned = []
        owned_targets = {int(target["pid"]) for target in result.get("target", []) if target.get("pid")}
        for pid, info in test_processes().items():
            if pid in before:
                continue
            orphan_placeholder = info["parent"] == 1 and info["state"].startswith("T")
            if pid not in owned_targets and not orphan_placeholder:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
                if info["state"].startswith("T"):
                    os.kill(pid, signal.SIGCONT)
                cleaned.append(pid)
            except ProcessLookupError:
                pass
        result["cleanedTestPIDs"] = cleaned
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return result


results = []
for template in ["Time Profiler", "Allocations", "Leaks"]:
    results.append(record(template, 3, template.lower().replace(" ", "-")))
for count in range(5):
    results.append(record("Activity Monitor", count, f"activity-{count}"))
report = {"recordings": results,
          "powerProfiler": "Verified unsupported on macOS by prior recording; Power Profiler requires iOS/iPadOS.",
          "note": "Recording overhead is excluded from the 420-second baseline; Activity Monitor schemas are inspected for available metrics."}
(OUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print("Profiling results:", OUT, flush=True)
if not all(item.get("appCompleted") for item in results):
    raise SystemExit(1)

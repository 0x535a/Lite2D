#!/usr/bin/env python3
"""0–4 instance baseline, each with stationary and moving in-process targets."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--static-seconds", type=int, default=300)
parser.add_argument("--moving-seconds", type=int, default=120)
parser.add_argument("--counts", nargs="+", type=int, default=[0, 1, 2, 3, 4])
parser.add_argument("--hide-after-warmup", type=int, choices=range(5), default=0)
parser.add_argument("--output", type=Path, default=root / ".local/verification/performance")
args = parser.parse_args()
assets = [root / ".local/models/bilibili-22/model.json", root / ".local/models/bilibili-33/model.json",
          root / ".local/models/bilibili-22/model.json", root / ".local/models/bilibili-33/model.json"]
application = os.environ.get("LITE2D_APP_PATH", str(root / "dist/Lite2D.app/Contents/MacOS/Lite2D"))
for count in args.counts:
    if count not in range(5):
        raise ValueError("This baseline matrix covers 0–4 instances")
    out = args.output / str(count)
    out.mkdir(parents=True, exist_ok=True)
    descriptors = []
    for index in range(count):
        descriptors.append(dict(id=str(uuid.uuid4()), displayName=f"baseline-{index + 1}", modelPath=str(assets[index]),
                                windowFrame=dict(x=80+index*380, y=100, width=360, height=480), scale=1,
                                isVisible=True, trackingEnabled=True, trackingSmoothingSeconds=0.14,
                                interactionMode="passthrough", targetFPS=30, animationPaused=False, zOrder=index))
    settings = out / "settings.json"
    settings.write_text(json.dumps(dict(schemaVersion=2, instances=descriptors), indent=2) + "\n")
    env = dict(os.environ, LITE2D_SETTINGS_PATH=str(settings), LITE2D_BENCH_OUTPUT=str(out),
               LITE2D_STATIC_SECONDS=str(args.static_seconds), LITE2D_MOVING_SECONDS=str(args.moving_seconds))
    env["LITE2D_HIDE_AFTER_WARMUP"] = str(args.hide_after_warmup)
    print(f"Starting {count} instances: {args.static_seconds}s stationary + {args.moving_seconds}s moving target", flush=True)
    with (out / "run.log").open("w") as log:
        process = subprocess.Popen([application, "--benchmark"],
                                   cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        (args.output / "active-process.json").write_text(json.dumps(dict(pid=process.pid, count=count, started=time.time())) + "\n")
        try:
            result = process.wait(timeout=args.static_seconds + args.moving_seconds + 90)
        except BaseException:
            process.terminate()
            process.wait(timeout=15)
            raise
    if result:
        raise RuntimeError(f"{count}-instance benchmark exit={result}: {out / 'run.log'}")
    summary = json.loads((out / "summary.json").read_text())
    print(f"Completed {count}: CPU {summary['meanCPUPercentOneCore100']:.2f}%, elapsed {summary['durationSeconds']:.1f}s", flush=True)
print("All requested baseline scenarios completed", flush=True)

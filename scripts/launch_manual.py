#!/usr/bin/env python3
"""Prepare a separately identified local app session for human acceptance tests.

Uses an isolated settings file so manual menu operations cannot edit the long
benchmark's descriptors or the user's daily layout. Does not automate input.
"""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid
import time

root = Path(__file__).resolve().parents[1]
out = root / ".local/verification/manual"
out.mkdir(parents=True, exist_ok=True)
pid_path = out / "pid.json"
if pid_path.exists():
    old = json.loads(pid_path.read_text())
    probe = subprocess.run(["ps", "-p", str(old["pid"]), "-o", "command="], capture_output=True, text=True)
    if probe.returncode == 0 and str(out / "Lite2D-Manual.app/Contents/MacOS/Lite2D") in probe.stdout:
        print(f"Manual session already running: PID {old['pid']}; look for the 手测 model names in the menu.")
        raise SystemExit(0)
app = out / "Lite2D-Manual.app"
shutil.copytree(root / "dist/Lite2D.app", app, dirs_exist_ok=True)
info = app / "Contents/Info.plist"
plist = plistlib.loads(info.read_bytes())
plist["CFBundleIdentifier"] = "local.lite2d.player.manual-acceptance"
plist["CFBundleName"] = "Lite2D 手动验收"
info.write_bytes(plistlib.dumps(plist))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
settings = out / "settings.json"
if not settings.exists():
    descriptors = []
    for index, name in enumerate(["bilibili-22", "bilibili-33", "bilibili-22"]):
        model = root / ".local/models" / name / "model.json"
        if not model.exists():
            raise FileNotFoundError(f"Prepare selected models first: {model}")
        descriptors.append(dict(id=str(uuid.uuid4()), displayName=f"手测 {index+1} · {name}", modelPath=str(model),
                                windowFrame=dict(x=100+index*420, y=100, width=360, height=480),
                                targetFPS=30, trackingEnabled=True, interactionMode="passthrough"))
    settings.write_text(json.dumps(dict(schemaVersion=2, instances=descriptors), ensure_ascii=False, indent=2) + "\n")
with (out / "app.log").open("a") as log:
    process = subprocess.Popen([str(app / "Contents/MacOS/Lite2D")], cwd=root,
                               env=dict(os.environ, LITE2D_SETTINGS_PATH=str(settings)),
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
pid_path.write_text(json.dumps(dict(pid=process.pid, settings=str(settings), app=str(app), started=time.time(),
                                   binarySHA256=hashlib.sha256((app / "Contents/MacOS/Lite2D").read_bytes()).hexdigest()), indent=2) + "\n")
print(f"Manual session started: PID {process.pid}; model names begin with 手测.")
print(f"Settings: {settings}")

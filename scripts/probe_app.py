#!/usr/bin/env python3
"""Launch a bounded app self-probe, inspecting its own GPU buffer, without UI control."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model", type=Path)
parser.add_argument("--name", default="app")
args = parser.parse_args()
output = root / ".local/verification" / args.name
output.mkdir(parents=True, exist_ok=True)
with (output / "run.log").open("w") as log:
    application = os.environ.get("LITE2D_APP_PATH", str(root / "dist/Lite2D.app/Contents/MacOS/Lite2D"))
    result = subprocess.run([application, str(args.model.resolve())],
                            env=dict(os.environ, LITE2D_PROBE_DIR=str(output)), stdout=log,
                            stderr=subprocess.STDOUT, timeout=45)
text = (output / "run.log").read_text()
match = re.search(r"APP_PROBE width=(\d+) height=(\d+) frames=(\d+) glError=(\d+)", text)
if result.returncode or not match or match[4] != "0":
    print(text[-4000:])
    raise RuntimeError(f"App probe failed: exit={result.returncode}")
w, h = map(int, (match[1], match[2]))
frame = output / "app-frame.rgba"
raw = frame.read_bytes()
if not any(raw[0::4]) or not any(raw[1::4]) or not any(raw[2::4]):
    raise RuntimeError("Rendered frame has an empty color channel")
subprocess.run([sys.executable, str(root / "scripts/inspect_frame.py"), str(frame), str(w), str(h)], check=True)
print(f"App exit=0, frames={match[3]}, GL error=0; artifacts: {output}")

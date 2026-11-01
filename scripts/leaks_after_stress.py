#!/usr/bin/env python3
"""Run real lifecycle stress, then scan a bounded quiescent process with leaks."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".local/verification/post-stress-leaks" / time.strftime("run-%Y%m%d-%H%M%S")
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run(["python3", str(ROOT / "scripts/create_test_fixtures.py")], check=True, stdout=subprocess.DEVNULL)
models = [ROOT / ".local/models/legacy-a/model.json", ROOT / ".local/models/legacy-b/model.json",
          ROOT / "vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.model3.json"]
env = dict(os.environ, LITE2D_SETTINGS_PATH=str(OUT / "settings.json"), LITE2D_TEST_OUTPUT=str(OUT),
           LITE2D_LEAK_SCAN_HOLD_SECONDS="30")
with (OUT / "app.log").open("w") as log:
    process = subprocess.Popen([str(ROOT / "dist/Lite2D.app/Contents/MacOS/Lite2D"), "--self-test", *map(str, models)],
                               cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 120
        while not (OUT / "passed.json").exists():
            if process.poll() is not None:
                raise RuntimeError(f"Stress exited before success: {process.returncode}; {OUT / 'app.log'}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Stress did not complete within its watchdog")
            time.sleep(0.5)
        checks = json.loads((OUT / "passed.json").read_text())
        if not checks.get("passed"):
            raise RuntimeError("Lifecycle stress reported failure")
        with (OUT / "leaks.txt").open("w") as leak_log:
            scan = subprocess.run(["leaks", str(process.pid)], stdout=leak_log, stderr=subprocess.STDOUT, timeout=20)
        text = (OUT / "leaks.txt").read_text()
        zero = "0 leaks for 0 total leaked bytes" in text
        result = dict(integrationChecks=len(checks["checks"]), scannerExit=scan.returncode, zeroLeaks=zero,
                      appExit=process.wait(timeout=45), directory=str(OUT))
        (OUT / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2), flush=True)
        if not zero or result["appExit"]:
            raise RuntimeError("Post-stress leak or exit check failed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)

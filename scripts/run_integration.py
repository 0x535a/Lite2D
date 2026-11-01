#!/usr/bin/env python3
"""Run in-app integration tests and verify state in a second fresh process."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "scripts/create_test_fixtures.py")], check=True, stdout=subprocess.DEVNULL)
output = Path(os.environ.get("LITE2D_INTEGRATION_OUTPUT", str(root / ".local/verification/integration")))
output.mkdir(parents=True, exist_ok=True)
for name in ["passed.json", "failed.json"]:
    previous = output / name
    if previous.exists():
        previous.rename(output / f"previous-{uuid.uuid4().hex}-{name}")
settings = output / "settings.json"
if settings.exists():
    settings.rename(output / f"previous-settings-{uuid.uuid4().hex}.json")
env = dict(os.environ, LITE2D_SETTINGS_PATH=str(settings), LITE2D_TEST_OUTPUT=str(output))
app = os.environ.get("LITE2D_APP_PATH", str(root / "dist/Lite2D.app/Contents/MacOS/Lite2D"))
models = [root / ".local/models/bilibili-22/model.json", root / ".local/models/bilibili-33/model.json",
          root / "vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.model3.json"]
with (output / "integration.log").open("w") as log:
    run = subprocess.run([app, "--self-test", *map(str, models)], env=env, cwd=root,
                         stdout=log, stderr=subprocess.STDOUT, timeout=180)
if run.returncode:
    print((output / "integration.log").read_text()[-6000:])
    sys.exit(run.returncode or 1)
first = json.loads((output / "passed.json").read_text())
assert first["passed"]
(output / "passed.json").rename(output / "integration-passed.json")
expected = json.loads((output / "expected-settings.json").read_text())
missing = dict(expected["instances"][0], id=str(uuid.uuid4()), displayName="Missing asset test",
               modelPath=str(output / "missing/model.json"))
expected["instances"].append(missing)
offline = dict(expected["instances"][0], id=str(uuid.uuid4()), displayName="Offline bound display test",
               displayUUID=str(uuid.uuid4()).upper(), boundDisplayName="Disconnected fixture display",
               displayBindingVersion=1, displayPosition=dict(x=80, y=50), isVisible=True)
expected["instances"].append(offline)
encoded = json.dumps(expected, indent=2) + "\n"
settings.write_text(encoded)
(output / "expected-settings.json").write_text(encoded)
with (output / "restore.log").open("w") as log:
    restored = subprocess.run([app, "--verify-restore"], env=env, cwd=root,
                              stdout=log, stderr=subprocess.STDOUT, timeout=45)
if restored.returncode:
    print((output / "restore.log").read_text()[-5000:])
    sys.exit(restored.returncode or 1)
second = json.loads((output / "passed.json").read_text())
assert second["passed"]
(output / "restore-passed.json").write_text(json.dumps(second, indent=2) + "\n")
for meta in output.glob("*.json"):
    data = json.loads(meta.read_text())
    if isinstance(data, dict) and "width" in data and meta.with_suffix(".rgba").exists():
        subprocess.run([sys.executable, str(root / "scripts/inspect_frame.py"), str(meta.with_suffix(".rgba")),
                        str(data["width"]), str(data["height"])], check=True, stdout=subprocess.DEVNULL)
print(json.dumps({"integrationChecks": len(first["checks"]), "restoreChecks": len(second["checks"]),
                  "fps": first["fps"], "artifacts": str(output)}, indent=2))

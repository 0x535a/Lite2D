#!/usr/bin/env python3
"""In-process native Companion verification; never drives mouse/keyboard or another app."""
import json
import os
from pathlib import Path
import subprocess
import uuid
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local/verification/companion'
OUT.mkdir(parents=True, exist_ok=True)
settings = OUT / 'settings.json'
if settings.exists(): settings.unlink()
suite = f'local.lite2d.companion.{uuid.uuid4().hex}'
env = dict(os.environ, LITE2D_SETTINGS_PATH=str(settings), LITE2D_COMPANION_ROOT=str(OUT / 'Companion'),
           LITE2D_TEST_OUTPUT=str(OUT), LITE2D_PREFERENCES_SUITE=suite)
pack = ROOT / 'doc/companion/persona_pack'
if pack.exists(): env['LITE2D_PERSONA_PACK'] = str(pack)
models = [ROOT / '.local/models/22/model.json', ROOT / '.local/models/33/model.json']
if not all(p.exists() for p in models):
    installed = Path.home() / 'Library/Application Support/Lite2D/settings.json'
    data = json.loads(installed.read_text()) if installed.exists() else {}
    local = [Path(r['modelPath']) for r in data.get('instances', [])[:2]]
    models = local if len(local) == 2 and all(p.exists() for p in local) else [ROOT / 'vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.model3.json'] * 2
try:
    with (OUT / 'native.log').open('w') as log:
        result = subprocess.run([str(ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D'), '--companion-self-test', *map(str, models)],
                                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=75)
    report = OUT / ('passed.json' if result.returncode == 0 else 'failed.json')
    print(report.read_text() if report.exists() else (OUT / 'native.log').read_text()[-4000:])
    if result.returncode: raise SystemExit(result.returncode)
finally:
    subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

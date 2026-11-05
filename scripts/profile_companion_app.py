#!/usr/bin/env python3
"""Sequential whole-app idle comparison with identical isolated model settings.

No mouse/keyboard/window automation. Models are loaded from existing local assets;
only copied settings and synthetic Claude history are written under temporary roots.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('profile_runtime', ROOT / 'scripts/profile_companion_runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
OUT = runtime.OUT


def measure(kind, executable, seconds):
    original = json.loads((Path.home() / 'Library/Application Support/Lite2D/settings.json').read_text())
    for role in original['instances']:
        role['trackingEnabled'] = False
        role['targetFPS'] = 30
    with tempfile.TemporaryDirectory(prefix=f'lite2d-app-profile-{kind}-') as tmp:
        root = Path(tmp)
        (root / 'settings.json').write_text(json.dumps(original))
        companion = root / 'Companion'
        companion.mkdir()
        (companion / 'settings.json').write_text(json.dumps({'enabled': True, 'paused': False, 'intervalMinutes': 0, 'hourlyRequests': 12, 'model': '',
            'nodePath': shutil.which('node'), 'opencodePath': shutil.which('opencode'), 'codexPath': shutil.which('codex'),
            'sources': {'claude': {'enabled': True}, 'codex': {'enabled': False}, 'opencode': {'enabled': False}},
            'characters': {r['id']: {'enabled': False, 'gaze': True} for r in original['instances']}}))
        claude = runtime.fixture(root)
        env = dict(os.environ, LITE2D_SETTINGS_PATH=str(root / 'settings.json'), LITE2D_COMPANION_ROOT=str(companion),
                   CLAUDE_CONFIG_DIR=str(claude), LITE2D_PREFERENCES_SUITE=f'local.lite2d.profile.{kind}.{os.getpid()}')
        child = subprocess.Popen([str(executable)], env=env, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        start = time.monotonic()
        samples = []
        try:
            while time.monotonic() - start < seconds:
                if child.poll() is not None:
                    raise RuntimeError(f'{kind} app exited unexpectedly: {child.returncode}')
                rows = runtime.tree(child.pid)
                samples.append({'elapsed': time.monotonic() - start, 'processes': rows,
                                'footprintSum': sum(r['footprint'] for r in rows), 'rssSum': sum(r['rss'] for r in rows),
                                'cpuSum': sum(r['cpuSeconds'] for r in rows)})
                time.sleep(1)
            quiet = samples[-10:]
            summary = {'kind': kind, 'seconds': seconds, 'models': len(original['instances']), 'targetFPS': 30, 'mouseTracking': False,
                       'source': 'synthetic Claude fixtures; no generation', 'quietFootprintMeanMiB': sum(s['footprintSum'] for s in quiet) / len(quiet) / 1048576,
                       'quietRSSMeanMiB': sum(s['rssSum'] for s in quiet) / len(quiet) / 1048576,
                       'quietCPUSeconds': quiet[-1]['cpuSum'] - quiet[0]['cpuSum'], 'quietProcesses': quiet[-1]['processes']}
        finally:
            owned = runtime.tree(child.pid)
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            time.sleep(1)
            for row in owned:
                if row['pid'] == child.pid:
                    continue
                command = subprocess.run(['ps', '-p', str(row['pid']), '-o', 'command='], capture_output=True, text=True).stdout
                if '/Resources/Companion/' in command:
                    try:
                        os.kill(row['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            subprocess.run(['defaults', 'delete', env['LITE2D_PREFERENCES_SUITE']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (OUT / f'whole-app-{kind}.json').write_text(json.dumps({'summary': summary, 'samples': samples}, indent=2))
        print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=75)
    args = parser.parse_args()
    for kind, app in [('old-node', OUT / 'baseline-app/Lite2D.app/Contents/MacOS/Lite2D'), ('new-swift', ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D')]:
        measure(kind, app, args.seconds)

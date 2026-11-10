#!/usr/bin/env python3
"""Offline native Companion management. No model requests or desktop automation.

Close Lite2D before using a production data root. The native Controller holds an
exclusive root lock; a second owner fails before opening or migrating SQLite.
JSON commands use the same host-only boundary as the application's memory UI.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {
    'memory_items': 'memory.items', 'memory_forget': 'memory.items',
    'reflection_preview': 'memory.items', 'reflection_commit': 'memory.items',
    'reflection_cancel': 'memory.items', 'growth_commit': 'memory.items',
    'growth_rollback': 'memory.items', 'growth_cancel': 'memory.items',
    'world_seed_preview': 'world_seed.preview', 'world_seed_commit': 'world_seed.committed',
    'world_seed_rollback': 'world_seed.rolled_back', 'persona_preview': 'persona.preview', 'persona': 'persona',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='Explicit Companion data root (app must be closed)')
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D')
    parser.add_argument('--command', type=Path, help='JSON command file; default: stdin')
    parser.add_argument('--scan', action='store_true', help='Read-only migration inventory; does not launch the app or mutate SQLite')
    args = parser.parse_args()
    if args.scan:
        root = args.root.resolve()
        report = {'root': str(root), 'readOnly': True, 'schemaVersion': None, 'legacyCandidates': [], 'personas': [], 'policy': 'Legacy blobs remain imported, unconfirmed material; no automatic locked identity extraction.'}
        database = root / 'state.sqlite'
        if database.is_file():
            with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
                report['schemaVersion'] = db.execute('PRAGMA user_version').fetchone()[0]
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='state'").fetchone():
                    for key, encoded in db.execute("SELECT key,value FROM state WHERE key LIKE 'memory:%'"):
                        value = json.loads(encoded)
                        if isinstance(value, str) and value.strip():
                            report['legacyCandidates'].append({'characterId': key[7:], 'bytes': len(value.encode()), 'sha256': hashlib.sha256(value.encode()).hexdigest(), 'risk': 'Unclassified blob; does not establish identity or firsthand experience'})
        for persona in sorted(root.glob('characters/*/persona.md')):
            if persona.is_symlink():
                continue
            report['personas'].append({'characterId': persona.parent.name, 'sha256': hashlib.sha256(persona.read_bytes()).hexdigest()})
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    command = json.loads(args.command.read_text() if args.command else sys.stdin.read())
    kind = command.get('type') if isinstance(command, dict) else None
    if kind not in ALLOWED:
        parser.error('Only supported offline management commands are allowed')
    app = args.app.resolve()
    if not app.is_file():
        parser.error(f'Build the application first: {app}')
    env = dict(os.environ, LITE2D_NATIVE_PROBE_ROOT=str(args.root.resolve()), LITE2D_PROBE_MANAGE_OPENCODE_SERVICE='0')
    env.pop('LITE2D_PROBE_PROVIDERS', None)
    # EOF closes the native runtime after the single command. Automatic scheduling
    # is disabled by the probe and no enabled-role configuration is supplied.
    result = subprocess.run([str(app), '--companion-runtime-probe'], input=json.dumps(command) + '\n',
                            capture_output=True, text=True, env=env, timeout=45)
    events = []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    errors = [event for event in events if event.get('type') in ('error', 'probe.error')]
    if result.returncode or errors:
        print(json.dumps(errors or {'error': 'Native Controller exited', 'status': result.returncode}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    response = next((event for event in events if event.get('type') == ALLOWED[kind]), None)
    if response is None:
        print('Native Controller returned no management result', file=sys.stderr)
        return 1
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Sign daily builds with a locally pinned certificate; never silently use ad-hoc."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOCAL_IDENTITY = ROOT / '.local/codesign-identity'


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--identity', help='Certificate SHA-1 fingerprint (not a private key)')
    parser.add_argument('--check-identity', action='store_true')
    parser.add_argument('--allow-adhoc', action='store_true', help='Explicitly allow disposable builds signed with identity -')
    args = parser.parse_args()
    identity = args.identity or os.environ.get('LITE2D_CODESIGN_IDENTITY')
    if not identity and LOCAL_IDENTITY.exists():
        identity = LOCAL_IDENTITY.read_text().strip()
    if not identity:
        parser.error('Configure a certificate SHA-1 in .local/codesign-identity or LITE2D_CODESIGN_IDENTITY. For disposable builds only, explicitly use --identity - --allow-adhoc.')
    identity = identity.strip().upper()
    if identity == '-':
        if not args.allow_adhoc:
            parser.error('Ad-hoc signing changes the TCC identity across builds. It requires explicit --allow-adhoc.')
    else:
        if not re.fullmatch(r'[0-9A-F]{40}', identity):
            parser.error('Use an exact 40-digit certificate SHA-1 fingerprint from security find-identity -v -p codesigning.')
        identities = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning').stdout
        available = set(re.findall(r'^\s*\d+\)\s+([0-9A-F]{40})\s', identities, re.M))
        if identity not in available:
            parser.error('The configured code-signing certificate/private key is unavailable or invalid; refusing to change signing identity.')
    if args.check_identity:
        print(json.dumps({'identity': identity, 'adhoc': identity == '-'}))
        return
    if not args.app:
        parser.error('--app is required when signing')
    app = args.app.resolve()
    with (app / 'Contents/Info.plist').open('rb') as stream:
        bundle_id = plistlib.load(stream)['CFBundleIdentifier']
    run('/usr/bin/codesign', '--force', '--sign', identity, str(app))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    requirement_output = run('/usr/bin/codesign', '-d', '-r-', str(app))
    requirement = next(line.split('designated => ', 1)[1] for line in (requirement_output.stdout + requirement_output.stderr).splitlines() if 'designated => ' in line)
    details = run('/usr/bin/codesign', '-dv', '--verbose=4', str(app)).stderr
    if identity != '-':
        if 'cdhash' in requirement or 'Signature=adhoc' in details or 'TeamIdentifier=not set' in details:
            raise RuntimeError('Certificate signing did not produce a stable designated requirement and Team ID')
        # Check the leaf certificate, not just that some signature is intact.
        run('/usr/bin/codesign', '--verify', '--strict', '-R', f'=certificate leaf = H"{identity}"', str(app))
    print(json.dumps({'app': str(app), 'bundleId': bundle_id, 'identity': identity, 'designatedRequirement': requirement}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr or error.stdout or str(error))

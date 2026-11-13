#!/usr/bin/env python3
"""Verify identity continuity across different signed bundles, without accessing TCC."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIGNER = ROOT / 'scripts/sign_app.py'
APP = ROOT / 'dist/Lite2D.app'


def run(*args):
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout + result.stderr


def requirement(app):
    output = run('codesign', '-d', '-r-', str(app))
    return next(line.split('designated => ', 1)[1] for line in output.splitlines() if 'designated => ' in line)


original_requirement = requirement(APP)
assert 'cdhash' not in original_requirement
details = run('codesign', '-dv', '--verbose=4', str(APP))
assert 'Signature=adhoc' not in details and 'TeamIdentifier=not set' not in details
run('codesign', '--verify', '--deep', '--strict', str(APP))
with tempfile.TemporaryDirectory(prefix='lite2d-signing-') as temporary:
    variant = Path(temporary) / 'Lite2D.app'
    shutil.copytree(APP, variant, symlinks=True)
    info = variant / 'Contents/Info.plist'
    value = plistlib.loads(info.read_bytes())
    value['Lite2DSigningRegressionFixture'] = 'different signed resources'
    info.write_bytes(plistlib.dumps(value))
    run('python3', str(SIGNER), '--app', str(variant))
    assert requirement(variant) == original_requirement
    new_details = run('codesign', '-dv', '--verbose=4', str(variant))
    cdhash = lambda text: re.search(r'^CDHash=(.+)$', text, re.M).group(1)
    assert cdhash(details) != cdhash(new_details), 'Fixture must change the signed content'
    run('codesign', '--verify', '--deep', '--strict', '-R', '=' + original_requirement, str(variant))
    run('codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement(variant), str(APP))
    signature_before = (variant / 'Contents/_CodeSignature/CodeResources').read_bytes()
    for identity in ['0' * 40, '-']:
        rejected = subprocess.run(['python3', str(SIGNER), '--app', str(variant), '--identity', identity], capture_output=True)
        assert rejected.returncode != 0
        assert signature_before == (variant / 'Contents/_CodeSignature/CodeResources').read_bytes()
        run('codesign', '--verify', '--strict', str(variant))
print(json.dumps({'passed': True, 'differentContentSameRequirement': True, 'mutualRequirementChecks': True, 'missingCertificateRejected': True, 'implicitAdhocRejected': True, 'actualTCCGrantPersistenceTested': False, 'requirement': original_requirement}, indent=2))

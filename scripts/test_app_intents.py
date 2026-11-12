#!/usr/bin/env python3
"""Validate the exported App Intents contracts without querying Focus or running actions."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/Lite2D.app'
metadata = json.loads((APP / 'Contents/Resources/Metadata.appintents/extract.actionsdata').read_text())
actions = metadata['actions']
focus = actions['CompanionQuietFocusFilter']
activity = actions['CompanionActivityIntent']
assert 'com.apple.link.systemProtocol.FocusConfiguration' in focus['systemProtocols']
assert [p['name'] for p in focus['parameters']] == ['quiet']
assert [p['name'] for p in activity['parameters']] == ['activity']
assert not focus['openAppWhenRun'] and not activity['openAppWhenRun']
assert activity['parameters'][0]['valueType']['linkEnumeration']['wrapper']['identifier'] == 'CompanionExplicitActivity'
values = next(value for value in metadata['enums'] if value['identifier'] == 'CompanionExplicitActivity')
assert {value['identifier'] for value in values['cases']} == {'browsing', 'programming', 'writing', 'research', 'experiment', 'media', 'communication', 'idle', 'unknown'}
keys = set()
def collect(value):
    if isinstance(value, dict):
        if isinstance(value.get('key'), str) and value['key'].startswith(('focus.', 'activity.')):
            keys.add(value['key'])
        for child in value.values():
            collect(child)
    elif isinstance(value, list):
        for child in value:
            collect(child)
collect(metadata)
for language in ['en', 'zh-Hans', 'zh-Hant', 'ja']:
    path = APP / 'Contents/Resources' / (language + '.lproj') / 'Localizable.strings'
    localized = set(re.findall(r'^"([^"\n]+)"\s*=', path.read_text(), re.M))
    assert keys <= localized, (language, keys - localized)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
print('PASS: exported scoped Focus Filter, enum-only activity action, four-language metadata keys and signed bundle')

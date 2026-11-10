#!/usr/bin/env python3
"""Validate four-language resources and exercise localization with isolated preferences."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Resources/Localizations'
OUTPUT = ROOT / '.local/verification/localization'
OUTPUT.mkdir(parents=True, exist_ok=True)

catalogs = {}
for language in ['en', 'zh-Hans', 'zh-Hant', 'ja']:
    path = RESOURCES / f'{language}.lproj/Localizable.strings'
    values = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    # plutil accepts duplicate keys; detect those before dictionaries hide them.
    keys = re.findall(r'^"([^"]+)"\s*=', path.read_text(), re.M)
    assert len(keys) == len(set(keys)), f'Duplicate keys in {language}'
    catalogs[language] = values
english = catalogs['en']
for language, values in catalogs.items():
    assert values.keys() == english.keys(), f'Key mismatch in {language}'
    for key, value in values.items():
        assert value.strip(), f'Empty translation: {language}/{key}'
        assert sorted(re.findall(r'\{\d+\}', value)) == sorted(re.findall(r'\{\d+\}', english[key])), f'Placeholder mismatch: {language}/{key}'
for path in (ROOT / 'App').glob('*.swift'):
    for key in re.findall(r'(?:L10n\.(?:text|count|format)|\.key|GeneratedName\(key:)\(?(?:key:)?\s*"([a-z][\w.]+)"', path.read_text()):
        if key.endswith('.'):  # Enum-derived keys are checked below.
            continue
        assert key in english, f'Unknown key {key} in {path.name}'
for prefix, suffixes in {'settings.': ['appearance', 'interaction', 'advanced'], 'role.status.': ['failed', 'unbound', 'disconnected', 'hidden', 'all_hidden', 'editing', 'visible']}.items():
    assert all(prefix + suffix in english for suffix in suffixes)
for path in [ROOT / 'Bridge/ModelArchive.mm', ROOT / 'Bridge/Live2DBridge.mm', ROOT / 'Engine/NativeHost.mm', ROOT / 'Engine/LegacyHost.mm']:
    assert all(key in english for key in re.findall(r'"(error\.[a-z_]+)"', path.read_text()))

def bundle(name, languages):
    target = OUTPUT / f'{name}.bundle'
    target.mkdir(exist_ok=True)
    for language in languages:
        shutil.copytree(RESOURCES / f'{language}.lproj', target / f'{language}.lproj', dirs_exist_ok=True)
    return target

full = bundle('Full', catalogs)
fallback = bundle('Fallback', ['en'])
exe = OUTPUT / 'localization-tests'
sources = ['CompanionMonitorPresentation.swift', 'Localization.swift', 'DisplayLayout.swift', 'ModelInstanceSettings.swift', 'ModelFileValidator.swift', 'ModelOutfit.swift', 'ModelMotion.swift']
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *[str(ROOT / 'App' / source) for source in sources], str(ROOT / 'Tests/LocalizationTests.swift'), '-o', str(exe)], check=True)
suite = f'local.lite2d.tests.localization.{uuid.uuid4().hex}'
try:
    subprocess.run([str(exe), str(full), str(fallback)], env=dict(os.environ, LITE2D_PREFERENCES_SUITE=suite), check=True)
finally:
    subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f'PASS: {len(english)} keys × 4 languages; matching placeholders, Swift and native error keys')

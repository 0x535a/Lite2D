#!/usr/bin/env python3
"""Bounded importer regression tests. Fixtures and binaries remain under .local.

Optional --workshop PATH validates explicitly selected local EX workshop assets.
No personal settings or original model resources are modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workshop', type=Path)
args = parser.parse_args()
target = ROOT / '.local/verification/model-import'
if target.exists():
    shutil.rmtree(target)
target.mkdir(parents=True)
subprocess.run(['python3', str(ROOT / 'scripts/create_test_fixtures.py')], check=True, stdout=subprocess.DEVNULL)
fixture = ROOT / '.local/verification/fixtures/native-minimal'
shutil.copytree(fixture, target / 'plain')
with zipfile.ZipFile(target / 'plain.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in fixture.rglob('*'):
        if file.is_file():
            archive.write(file, '角色/' + str(file.relative_to(fixture)))

def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False))

native = json.loads((fixture / 'model.model3.json').read_text())
refs = native['FileReferences']
# Use real native data to allow subsequent in-app rendering of imported outfits.
payloads = {'core.bin3': (fixture / refs['Moc']).read_bytes()}
textures = []
for i, name in enumerate(refs['Textures']):
    key = f'texture-{i}.bin3'
    payloads[key] = (fixture / name).read_bytes()
    textures.append(key)
entry = {'Version': 3, 'FileReferences': {'Moc': 'core.bin3', 'Textures': textures}}
payloads['a.bin3'] = json.dumps(entry).encode()
payloads['b.bin3'] = json.dumps(dict(entry, Name='costume-b')).encode()
payloads['c.bin3'] = json.dumps(entry).encode()
manifest = {'type': 'LPK_1_0', 'id': 'test', 'name': '合集', 'encrypt': 'false', 'list': [
    {'character': '角色甲', 'costume': [{'name': '日常', 'path': 'a.bin3'}, {'name': '节日', 'path': 'b.bin3'}]},
    {'character': '角色乙', 'costume': [{'name': '默认', 'path': 'c.bin3'}]},
]}
metadata_name = hashlib.md5(b'config.mlve').hexdigest()

def make_lpk(path, metadata, resources):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(metadata_name, json.dumps(metadata, ensure_ascii=False))
        for name, data in resources.items():
            archive.writestr(name, data)

make_lpk(target / 'multi.lpk', manifest, payloads)
with zipfile.ZipFile(target / 'wrapped.wpk', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('config.json', json.dumps({'lpkFile': 'model.lpk', 'title': 'Test'}))
    archive.write(target / 'multi.lpk', 'model.lpk')
make_lpk(target / 'spine.lpk', manifest, dict(payloads, **{'a.bin3': b'{"skeleton": "spine"}'}))
make_lpk(target / 'encrypted-without-config.lpk', dict(manifest, encrypt='true'), payloads)

legacy_entry = {'model': 'core.moc', 'textures': ['texture.png'], 'motions': {'outfit': [{'command': 'change_cos outfit.model.json'}]}}
write_json(target / 'legacy/model.json', legacy_entry)
write_json(target / 'legacy/outfit.model.json', dict(legacy_entry, textures=['other.png'], motions={'default': [{'command': 'change_cos model.json'}]}))
(target / 'legacy/core.moc').write_bytes(b'moc' + b'\0' * 64)
(target / 'legacy/texture.png').write_bytes(b'fake texture for validation')
(target / 'legacy/other.png').write_bytes(b'fake alternate texture')
for name in ['a', 'b']:
    shutil.copytree(fixture, target / 'unrelated' / name)
shutil.copytree(fixture, target / 'partial/good')
write_json(target / 'partial/bad/model.model3.json', {'FileReferences': {'Moc': 'missing.moc3', 'Textures': ['missing.png']}})
shutil.copytree(fixture, target / 'missing-texture')
(target / 'missing-texture' / refs['Textures'][0]).unlink()
shutil.copytree(fixture, target / 'bad-sidecar')
write_json(target / 'bad-sidecar/model.model3.json.lite2d-outfits.json', [{'id': '', 'name': '默认'}, {'id': '../escape.json', 'name': 'bad'}])
(target / 'linked-folder').mkdir()
(target / 'linked-folder/link').symlink_to(fixture)
with zipfile.ZipFile(target / 'traversal.zip', 'w') as archive:
    archive.writestr('../escape', b'x')
with zipfile.ZipFile(target / 'link.zip', 'w') as archive:
    info = zipfile.ZipInfo('link')
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, '/tmp')
with zipfile.ZipFile(target / 'collision.zip', 'w') as archive:
    archive.writestr('a.json', b'a')
    archive.writestr('A.json', b'b')
(target / 'corrupt.zip').write_bytes(b'not a zip')

archive_object = target / 'ModelArchive.o'
subprocess.run(['xcrun', 'clang++', '-c', '-fobjc-arc', '-mmacosx-version-min=14.0',
                str(ROOT / 'Bridge/ModelArchive.mm'), '-o', str(archive_object)], check=True)
binary = target / 'import-tests'
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-import-objc-header', str(ROOT / 'Bridge/ModelArchive.h'),
                *[str(ROOT / 'App' / f) for f in ['Localization.swift', 'ModelFileValidator.swift', 'ModelOutfit.swift', 'ModelLibraryImporter.swift', 'ModelPackageDecoder.swift']],
                str(ROOT / 'Tests/ModelImportTests.swift'), str(archive_object), '-larchive', '-lc++', '-framework', 'Foundation', '-o', str(binary)], check=True)
command = [str(binary), str(target)]
if args.workshop:
    command.append(str(args.workshop.resolve()))
subprocess.run(command, check=True)

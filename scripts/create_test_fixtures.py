#!/usr/bin/env python3
"""Create local minimal/missing-resource fixtures from an official model.

Only .local/ is written. Real files, not escaping symlinks, preserve the asset
containment rule. Generated Cubism data never becomes a source distribution.
"""
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
source = root / "vendor/CubismNativeSamples/Samples/Resources/Hiyori"
original = json.loads((source / "Hiyori.model3.json").read_text())
refs = original["FileReferences"]
fixtures = root / ".local/verification/fixtures"
for name in ["native-minimal", "native-missing-moc", "native-missing-texture"]:
    directory = fixtures / name
    directory.mkdir(parents=True, exist_ok=True)
    required = [refs["Moc"], *refs["Textures"]]
    for relative in required:
        destination = directory / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            shutil.copyfile(source / relative, destination)
    fixture_refs = {"Moc": refs["Moc"], "Textures": refs["Textures"]}
    if name.endswith("missing-moc"):
        fixture_refs["Moc"] = "missing.moc3"
    if name.endswith("missing-texture"):
        fixture_refs["Textures"] = ["missing.png", *refs["Textures"][1:]]
    entry = directory / "model.model3.json"
    entry.write_text(json.dumps({"Version": 3, "FileReferences": fixture_refs}, indent=2) + "\n")
    print(entry)

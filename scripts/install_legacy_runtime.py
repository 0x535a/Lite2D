#!/usr/bin/env python3
"""Copy an existing personal Cubism 2 runtime into the ignored resource folder."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="path to a Cubism 2 runtime you are authorized to use")
args = parser.parse_args()
data = args.source.read_bytes()
if b"Live2DModelWebGL" not in data or b"Live2DMotion" not in data:
    raise ValueError("Not a recognizable Cubism 2 runtime")
destination = root / "Resources/LegacyRuntime"
destination.mkdir(parents=True, exist_ok=True)
shutil.copyfile(args.source, destination / "legacy-core.js")
(destination / "source-receipt.json").write_text(json.dumps({
    "source": str(args.source), "sha256": hashlib.sha256(data).hexdigest(),
    "note": "Existing local runtime; proprietary, not part of the source distribution."
}, indent=2) + "\n")
print(destination / "legacy-core.js")

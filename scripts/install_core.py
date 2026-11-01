#!/usr/bin/env python3
"""Install official Native R5 Core locally, without replacing pinned sources."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PAGE = "https://www.live2d.com/en/sdk/download/native/"
SCRIPT = "https://cubism.live2d.com/sdk-native/js/download.js"
URL = "https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-5-r.5.zip"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="an official SDK ZIP already downloaded")
    parser.add_argument("--accept-sdk-license", action="store_true",
                        help="explicit acceptance of the official SDK software agreements")
    args = parser.parse_args()
    if not args.archive and not args.accept_sdk_license:
        parser.error(f"download requires explicit license acceptance; read {PAGE}")
    cache = ROOT / ".local" / "sdk"
    cache.mkdir(parents=True, exist_ok=True)
    archive = args.archive or cache / "CubismSdkForNative-5-r.5.zip"
    if not args.archive:
        listing = subprocess.run(["curl", "-fLsS", "--retry", "2", "--max-time", "60", SCRIPT],
                                 check=True, capture_output=True, text=True).stdout
        if 'CubismSdkForNative-5-r.5.zip' not in listing:
            raise RuntimeError("R5 archive no longer listed by official download page")
        partial = archive.with_suffix(".partial")
        subprocess.run(["curl", "-fL", "--retry", "2", "--max-time", "300",
                        "--output", str(partial), URL], check=True)
        partial.replace(archive)
    with zipfile.ZipFile(archive) as package:
        entries = [n for n in package.namelist() if "/Core/" in n and not n.endswith("/")]
        if not any(n.endswith("/Core/include/Live2DCubismCore.h") for n in entries):
            raise RuntimeError("Not a Native SDK archive with the expected Core header")
        # Copy only relative Core files; reject archive traversal and symlinks.
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            staging = Path(temporary)
            for name in entries:
                relative = Path(name.split("/Core/", 1)[1])
                if relative.is_absolute() or ".." in relative.parts:
                    raise RuntimeError(f"Unsafe archive path: {name}")
                item = package.getinfo(name)
                if (item.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError(f"Unexpected symlink: {name}")
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.read(name))
            expected = staging / "lib/macos/arm64/libLive2DCubismCore.a"
            if not expected.is_file():
                raise RuntimeError("Archive has no ARM64 macOS static Core")
            destination = ROOT / "vendor/CubismNativeSamples/Core"
            shutil.copytree(staging, destination, dirs_exist_ok=True)
    # Headers are proprietary SDK contents too. Upstream ignores binary Core
    # files but leaves include/ unignored; keep this installation local without
    # changing or committing the pinned dependency's .gitignore.
    repository = ROOT / "vendor/CubismNativeSamples"
    exclude = Path(subprocess.run(["git", "rev-parse", "--git-path", "info/exclude"],
                                 cwd=repository, check=True, capture_output=True, text=True).stdout.strip())
    if not exclude.is_absolute():
        exclude = repository / exclude
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text() if exclude.exists() else ""
    if "/Core/include/" not in existing.splitlines():
        exclude.write_text(existing.rstrip() + "\n/Core/include/\n")
    record = {"source": URL if not args.archive else str(archive.resolve()),
              "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
              "licensePage": PAGE}
    (cache / "core-install.json").write_text(json.dumps(record, indent=2) + "\n")
    print("Installed ARM64 Core; receipt: .local/sdk/core-install.json")


if __name__ == "__main__":
    main()

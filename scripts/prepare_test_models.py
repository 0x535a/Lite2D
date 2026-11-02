#!/usr/bin/env python3
"""Read explicitly selected installed Workshop packages into a local test cache.

Does not modify Steam files, execute model scripts, or redistribute model assets.
Runtime files are classified by content so Cubism 2 data is not mislabeled
as Cubism 3. Package identifiers and model choices are supplied locally.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def rolling_key(value):
    result = 0
    for character in value:
        result = (result * 31 + ord(character)) & 0xffffffff
    return result


def decode(seed, payload):
    output = bytearray(len(payload))
    for offset in range(0, len(payload), 1024):
        state = seed
        for index in range(offset, min(offset + 1024, len(payload))):
            state = ((2531011 + 214013 * state) >> 16) & 65535
            output[index] = payload[index] ^ (state & 255)
    return bytes(output)


def prepare(source, ident, destination):
    config = json.loads((source / ident / "config.json").read_text())
    package_path = source / ident / config["lpkFile"]
    if package_path.resolve().parent != (source / ident).resolve():
        raise ValueError("Package path escapes its model directory")
    with zipfile.ZipFile(package_path) as package:
        if sum(item.file_size for item in package.infolist()) > 512 * 1024 * 1024:
            raise ValueError("Package exceeds local preparation limit (512 MiB)")
        metadata = json.loads(package.read(hashlib.md5(b"config.mlve").hexdigest()))
        entry_path = metadata["list"][0]["costume"][0]["path"]

        def read(name, file_id):
            data = package.read(name)
            if str(metadata.get("encrypt", "false")).lower() == "true":
                data = decode(rolling_key(metadata["id"] + file_id + name + config["metaData"]), data)
            return data

        for file_id in dict.fromkeys([config.get("fileId", ""), ident]):
            try:
                entry = json.loads(read(entry_path, file_id))
                break
            except (ValueError, UnicodeError):
                continue
        else:
            raise ValueError(f"Cannot read model entry for {ident}")
        mapping, contents, payloads = {}, {}, {}
        for name in package.namelist():
            if not re.fullmatch(r"[0-9a-f]{32}\.bin3?", name):
                continue
            data = read(name, file_id)
            suffix = (".moc3" if data.startswith(b"MOC3") else ".moc" if data.startswith(b"moc")
                      else ".png" if data.startswith(b"\x89PNG") else ".jpg" if data.startswith(b"\xff\xd8")
                      else ".dat")
            try:
                contents[name] = json.loads(data)
                suffix = ".json"
            except (ValueError, UnicodeError):
                pass
            mapping[name] = name.rsplit(".", 1)[0] + suffix
            payloads[name] = data

        def remap(value):
            if isinstance(value, str):
                tokens = value.split()
                if len(tokens) == 2 and tokens[0] == "change_cos" and tokens[1] in mapping:
                    return "change_cos " + mapping[tokens[1]]
                return mapping.get(value, value)
            if isinstance(value, list):
                return [remap(item) for item in value]
            if isinstance(value, dict):
                return {key: remap(item) for key, item in value.items()}
            return value

        model = entry.get("model") or (entry.get("FileReferences") or {}).get("Moc")
        if not model or model not in payloads:
            raise ValueError("No Cubism model binary in entry")
        destination.mkdir(parents=True, exist_ok=True)
        for name, data in payloads.items():
            if name in contents:
                data = json.dumps(remap(contents[name]), ensure_ascii=False).encode()
            (destination / mapping[name]).write_bytes(data)
        entry_name = "model.model3.json" if mapping[model].endswith(".moc3") else "model.json"
        (destination / entry_name).write_text(json.dumps(remap(entry), ensure_ascii=False, indent=2) + "\n")
        receipt = {"workshopID": ident, "title": config["title"], "author": config.get("author"),
                   "description": config.get("description"), "source": str(package_path),
                   "sha256": hashlib.sha256(package_path.read_bytes()).hexdigest(),
                   "entry": entry_name, "format": Path(mapping[model]).suffix}
        (destination / "source-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        return destination / entry_name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.home() /
                        "Library/Application Support/Steam/steamapps/workshop/content/616720")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/models")
    parser.add_argument("--item", action="append", required=True, metavar="ID:ALIAS",
                        help="installed Workshop item and local fixture name, repeatable (e.g. 12345:legacy-a)")
    args = parser.parse_args()
    for item in args.item:
        ident, separator, label = item.partition(":")
        if not separator or not ident.isdecimal() or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", label):
            parser.error("each --item must be a numeric ID followed by a safe local fixture alias")
        print(prepare(args.source, ident, args.output / label))


if __name__ == "__main__":
    main()

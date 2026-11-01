#!/usr/bin/env python3
"""Inspect an application's RGBA readback and write an upright PNG artifact."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("frame", type=Path)
parser.add_argument("width", type=int)
parser.add_argument("height", type=int)
args = parser.parse_args()
raw = args.frame.read_bytes()
w, h = args.width, args.height
if len(raw) != w * h * 4:
    raise ValueError("Frame byte length does not match its dimensions")


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


scan = b"".join(b"\0" + raw[y*w*4:(y+1)*w*4] for y in range(h-1, -1, -1))
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(scan)) + chunk(b"IEND", b""))
args.frame.with_suffix(".png").write_bytes(png)
summary = {"width": w, "height": h, "sha256": hashlib.sha256(raw).hexdigest(),
           "visibleAlphaPixels": sum(value > 0 for value in raw[3::4]),
           "transparentPixels": sum(value == 0 for value in raw[3::4])}
args.frame.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary))

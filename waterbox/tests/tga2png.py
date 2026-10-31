#!/usr/bin/env python3
"""Turns the .tga a harness run wrote (--screenshot) into a .png beside it.

Usage: tga2png.py <file.tga> [<out.png>]
"""
import struct
import sys
import zlib

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else src[:-4] + ".png"
d = open(src, "rb").read()
w, h = struct.unpack("<HH", d[12:16])
px = d[18:]
rows = []
for y in range(h):
    row = bytearray(b"\x00")
    for x in range(w):
        b, g, r = px[(y * w + x) * 4:(y * w + x) * 4 + 3]
        row += bytes((r, g, b))
    rows.append(bytes(row))


def chunk(tag, body):
    return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))


with open(dst, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))

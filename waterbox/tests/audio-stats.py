#!/usr/bin/env python3
"""Says what is in a raw sound file the harness wrote (--audio-out): signed
16-bit little-endian stereo. Prints the loudness (RMS of the left channel)
over the whole file and over windows.

Usage: audio-stats.py <file.raw> [rate=48000] [window seconds=0.5]
"""
import array
import math
import sys

path = sys.argv[1]
rate = int(sys.argv[2]) if len(sys.argv) > 2 else 48000
win = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
a = array.array("h")
with open(path, "rb") as f:
    a.frombytes(f.read())
left = a[0::2]
n = len(left)
rms = math.sqrt(sum(x * x for x in left) / n) if n else 0.0
print(f"samples={n} seconds={n / rate:.2f} rms={rms:.1f} peak={max((abs(x) for x in left), default=0)}")
step = int(rate * win)
print("rms per window:", " ".join(f"{math.sqrt(sum(x * x for x in left[i:i + step]) / max(1, len(left[i:i + step]))):.0f}" for i in range(0, n, step)))

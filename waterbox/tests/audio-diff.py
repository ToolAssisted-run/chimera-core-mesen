#!/usr/bin/env python3
"""How much of a sound is one part's: the loudness (RMS of the left
channel) of two raw sound files the harness wrote (--audio-out, signed
16-bit little-endian stereo) and of their difference, sample by sample.

The EPSM checks run a cartridge twice, once as it is and once with the EPSM
taken out of its header, and compare: what differs is what the EPSM played.

Usage: audio-diff.py <with.raw> <without.raw>
Prints "with=<rms> without=<rms> difference=<rms>".
"""
import array
import math
import sys


def left(path):
    a = array.array("h")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    return a[0::2]


def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / len(xs)) if len(xs) else 0.0


a, b = left(sys.argv[1]), left(sys.argv[2])
n = min(len(a), len(b))
print("with=%.1f without=%.1f difference=%.1f" % (rms(a), rms(b), rms([a[i] - b[i] for i in range(n)])))

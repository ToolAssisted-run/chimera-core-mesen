#!/usr/bin/env python3
"""Builds the WonderSwan test cartridge this repository uses from
ws-test.asm (beside this file) with nasm, and writes its header's checksum.

Usage: make-ws-test.py <out dir>

Writes ws-test.ws (64 KiB). The same file is the test of the WonderSwan
Color machine: the machine, not the header, says which console runs it.
Needs nasm (https://nasm.us); tests/roms/ws-test.ws is the result, so the
tests themselves do not.

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "ws-test.bin")
        subprocess.run(["nasm", "-f", "bin", "-o", out, os.path.join(here, "ws-test.asm")], check=True)
        rom = bytearray(open(out, "rb").read())
    assert len(rom) == 0x10000, len(rom)
    total = sum(rom[:-2]) & 0xFFFF
    rom[-2:] = total.to_bytes(2, "little")
    with open(os.path.join(sys.argv[1], "ws-test.ws"), "wb") as f:
        f.write(rom)


if __name__ == "__main__":
    main()

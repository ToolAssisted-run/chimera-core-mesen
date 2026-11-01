#!/usr/bin/env python3
"""Builds the Game Boy Advance test cartridge this repository uses from
gba-test.s (beside this file) with LLVM's assembler and linker, and writes
its header's checksum.

Usage: make-gba-test.py <out dir>

Writes gba-test.gba (32 KiB), and gba-tilt.gba, the same program assembled
with TILT defined: a cartridge with a tilt sensor, which it reads. It runs without the console's BIOS when the
machine skips the boot screen (the setting "Game Boy Advance BIOS" at
"None", or "Skip Boot Screen" on). Needs clang, ld.lld and llvm-objcopy
(LLVM, Apache-2.0 with LLVM exceptions; version 20 was used, as clang-20,
ld.lld-20 and llvm-objcopy-20, or set CLANG, LLD and OBJCOPY);
tests/roms/gba-test.gba is the result, so the tests themselves do not.

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import shutil
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))


def tool(env, *names):
    if os.environ.get(env):
        return os.environ[env]
    for n in names:
        if shutil.which(n):
            return n
    sys.exit("%s not found (set %s)" % (names[0], env))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    clang = tool("CLANG", "clang-20", "clang")
    lld = tool("LLD", "ld.lld-20", "ld.lld")
    objcopy = tool("OBJCOPY", "llvm-objcopy-20", "llvm-objcopy")
    for name, defs in (("gba-test.gba", []), ("gba-tilt.gba", ["-Wa,-defsym,TILT=1"])):
        with tempfile.TemporaryDirectory() as tmp:
            obj, elf, out = (os.path.join(tmp, n) for n in ("gba-test.o", "gba-test.elf", "gba-test.bin"))
            subprocess.run([clang, "--target=armv4t-none-eabi"] + defs + ["-c", os.path.join(here, "gba-test.s"), "-o", obj],
                           check=True)
            subprocess.run([lld, "-Ttext=0x08000000", "-e", "_start", "--no-rosegment", obj, "-o", elf], check=True)
            subprocess.run([objcopy, "-O", "binary", "--only-section=.text", elf, out], check=True)
            code = open(out, "rb").read()
        assert len(code) <= 0x8000, len(code)
        rom = bytearray(0x8000)
        rom[:len(code)] = code
        # the header's checksum over 0xA0-0xBC, as the BIOS computes it
        rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF
        with open(os.path.join(sys.argv[1], name), "wb") as f:
            f.write(rom)


if __name__ == "__main__":
    main()

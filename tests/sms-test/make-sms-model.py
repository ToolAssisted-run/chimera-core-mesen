#!/usr/bin/env python3
"""Builds sms-model.sms, this repository's own Master System program for the
console revision (the setting Console Model: Mesen's Compatibility, Master
System 1 or Master System 2).

Usage: make-sms-model.py <out dir>

Mesen tells the revisions apart in two ways the program shows:
  - a read of port $3E (the memory control port, which no device answers):
    the first Master System puts the bus's last byte there, the others $FF
    (SmsMemoryManager::GetOpenBus). The program reads it once at power on
    and keeps it at RAM $C010;
  - the video chip's name table: with bit 0 of register 2 clear, the first
    Master System (and Mesen's Compatibility, which is the first's video
    chip, on NTSC) forces bit 10 of each name table address to 0, so the
    bottom third of the picture repeats the name table's top half; the
    Master System 2 does not (SmsVdp::UpdateDisplayMode). The program puts
    black tiles in the name table's first 16 rows and white ones in the
    last 8: the bottom third of the picture is white on the Master System 2
    and black on the others.
After that it does nothing (the display stays on).

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import sys


def program():
    out = bytearray()
    labels = {}

    def b(*data):
        out.extend(data)

    def reg(r, v):
        b(0x3E, v, 0xD3, 0xBF, 0x3E, 0x80 | r, 0xD3, 0xBF)  # LD A,v; OUT ($BF),A; LD A,$80|r; OUT ($BF),A

    def addr(a, code):
        b(0x3E, a & 0xFF, 0xD3, 0xBF, 0x3E, (a >> 8) | code, 0xD3, 0xBF)

    def fill(count, *values):
        # LD BC,count; loop: (LD A,v; OUT ($BE),A)...; DEC BC; LD A,B; OR C; JR NZ loop
        b(0x01, count & 0xFF, count >> 8)
        top = len(out)
        for v in values:
            b(0x3E, v, 0xD3, 0xBE)
        b(0x0B, 0x78, 0xB1, 0x20, 0)
        out[-1] = (top - len(out)) & 0xFF

    b(0xF3, 0xED, 0x56)                 # DI; IM 1
    b(0x31, 0xF0, 0xDF)                 # LD SP,$DFF0
    b(0xC3, 0x00, 0x01)                 # JP $0100 (past the NMI at $0066)
    out.extend(bytes(0x66 - len(out)))
    b(0xED, 0x45)                       # $0066: RETN (Pause)
    out.extend(bytes(0x100 - len(out)))
    b(0xDB, 0x3E)                       # IN A,($3E)
    b(0x32, 0x10, 0xC0)                 # LD ($C010),A
    reg(0, 0x06)                        # mode 4
    reg(1, 0x80)                        # display off while the memory is written
    reg(2, 0x0E)                        # name table at $3800, bit 0 clear
    reg(5, 0xFF)
    reg(6, 0xFF)
    reg(7, 0x00)                        # backdrop: colour 0
    reg(8, 0x00)
    reg(9, 0x00)
    reg(10, 0xFF)
    addr(0x0000, 0x40)
    fill(32, 0x00)                      # tile 0: colour 0
    fill(8, 0xFF, 0x00, 0x00, 0x00)     # tile 1: colour 1
    addr(0x3800, 0x40)
    fill(16 * 32 * 2, 0x00)             # rows 0-15: tile 0
    fill(8 * 32, 0x01, 0x00)            # rows 16-23: tile 1
    addr(0x3F00, 0x40)
    fill(1, 0xD0)                       # no sprites
    addr(0x0000, 0xC0)
    fill(1, 0x00)                       # colour 0 black
    fill(1, 0x3F)                       # colour 1 white
    reg(1, 0xC0)                        # display on
    top = len(out)
    b(0x18, (top - (len(out) + 2)) & 0xFF)  # JR $
    return bytes(out)


def cart():
    rom = bytearray(0x8000)
    code = program()
    rom[:len(code)] = code
    rom[0x7FF0:0x7FF8] = b"TMR SEGA"
    rom[0x7FFF] = 0x4C  # Master System, export, 32 KiB
    total = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA:0x7FFC] = total.to_bytes(2, "little")
    return bytes(rom)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(os.path.join(sys.argv[1], "sms-model.sms"), "wb") as f:
        f.write(cart())


if __name__ == "__main__":
    main()

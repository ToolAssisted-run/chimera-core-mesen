#!/usr/bin/env python3
"""Builds the PC Engine test HuCard this repository uses: a small HuC6280
program that keeps what it reads from the controller port in its RAM, and
shows and sounds it.

Usage: make-pce-test.py <out dir>

Writes pce-test.pce (8 KiB) and sgx-test.sgx (the same program; Mesen
builds a SuperGrafx for a .sgx file, or when the machine says so), and
pce-pad6.pce, which reads the port twice a frame for six-button pads (the
Avenue Pad 6): each reset of the port switches such a pad between its
usual half (directions, I, II, Select, Run) and its other half (no
direction held, which tells a six-button pad, and III, IV, V, VI on the
button bits). The first read goes to RAM $10-$14 as above, the second to
$18-$1C.

What the program does:
  - at power on it maps the I/O page and its RAM, sets the video chip's
    display timing (the values PC Engine programs commonly use) with the
    background on and the vertical blank flag enabled, and sets the sound
    chip's channel 0 to a square wave at full volume;
  - each frame it waits for the video chip's vertical blank flag, then
    reads the controller port the way a game reads a multitap (the
    TurboTap): the port is reset, and for each of five pads the direction
    half (SEL high) and the buttons half (SEL low) are read; a plain pad
    answers as the first. RAM $10-$14 hold the five pads, 1 for held: Up
    Right Down Left on bits 4-7, I II Select Run on bits 0-3. RAM $00
    counts frames;
  - the backdrop colour (colour 0) is pad 1's byte, and channel 0 plays at
    a frequency that byte gives.
RAM is the work RAM's first page ($2000 in the CPU's view).

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import sys


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.out = bytearray()
        self.labels = {}
        self.fix = []

    def pc(self):
        return self.origin + len(self.out)

    def label(self, name):
        self.labels[name] = self.pc()

    def b(self, *data):
        self.out += bytes(data)

    def br(self, op, name):
        self.b(op, 0)
        self.fix.append(("rel", len(self.out) - 1, name))

    def jmp(self, name):
        self.b(0x4C, 0, 0)
        self.fix.append(("abs", len(self.out) - 2, name))

    def resolve(self):
        for kind, at, name in self.fix:
            if kind == "rel":
                rel = self.labels[name] - (self.origin + at + 1)
                assert -128 <= rel < 128, name
                self.out[at] = rel & 0xFF
            else:
                self.out[at:at + 2] = self.labels[name].to_bytes(2, "little")
        return self.out


def vdc(a, reg, value):
    a.b(0x03, reg)                        # ST0: the register
    a.b(0x13, value & 0xFF, 0x23, value >> 8)  # ST1, ST2: its value


def program(passes=1):
    a = Asm(0xE000)
    a.label("reset")
    a.b(0x78, 0xD4, 0xD8)                 # SEI; CSH; CLD
    a.b(0xA9, 0xFF, 0x53, 0x01)           # LDA #$FF; TAM #1: I/O at $0000
    a.b(0xA9, 0xF8, 0x53, 0x02)           # LDA #$F8; TAM #2: RAM at $2000
    a.b(0xA2, 0xFF, 0x9A)                 # LDX #$FF; TXS
    a.b(0xA2, 0x00)
    a.label("clear")
    a.b(0x74, 0x00, 0xE8)                 # STZ $00,X; INX
    a.br(0xD0, "clear")
    a.b(0xA9, 0x07, 0x8D, 0x02, 0x14)     # $1402 = 7: no IRQ reaches the CPU
    vdc(a, 0x0A, 0x0202)                  # HSR
    vdc(a, 0x0B, 0x041F)                  # HDR
    vdc(a, 0x0C, 0x0F02)                  # VPR
    vdc(a, 0x0D, 0x00EF)                  # VDW
    vdc(a, 0x0E, 0x0003)                  # VCR
    vdc(a, 0x09, 0x0000)                  # MWR: 32x32 tiles
    vdc(a, 0x05, 0x0088)                  # CR: background on, vertical blank flag on
    a.b(0x9C, 0x00, 0x04)                 # STZ $0400: VCE dot clock
    # the sound chip's channel 0: a square wave at full volume
    a.b(0x9C, 0x00, 0x08)                 # select channel 0
    a.b(0xA9, 0xFF, 0x8D, 0x01, 0x08)     # main volume
    a.b(0x9C, 0x04, 0x08)                 # channel off: the waveform's index back to 0
    a.b(0xA2, 0x00)
    a.label("wave")
    a.b(0x8A, 0x29, 0x10, 0xF0, 0x02, 0xA9, 0x1F)  # TXA; AND #$10; BEQ +2; LDA #$1F
    a.b(0x8D, 0x06, 0x08, 0xE8, 0xE0, 0x20)        # STA $0806; INX; CPX #32
    a.br(0xD0, "wave")
    a.b(0xA9, 0xFF, 0x8D, 0x05, 0x08)     # balance
    a.b(0xA9, 0x9F, 0x8D, 0x04, 0x08)     # on, volume 31
    a.label("main")
    a.label("wait")
    a.b(0xAD, 0x00, 0x00, 0x29, 0x20)     # LDA $0000 (VDC status); AND #$20
    a.br(0xF0, "wait")
    for n in range(passes):
        # the multitap's reset: CLR high, then low
        a.b(0xA9, 0x01, 0x8D, 0x00, 0x10, 0xA9, 0x03, 0x8D, 0x00, 0x10, 0xA9, 0x01, 0x8D, 0x00, 0x10)
        a.b(0xA2, 0x00)
        a.label("pads%d" % n)
        a.b(0xA9, 0x01, 0x8D, 0x00, 0x10, 0xEA, 0xEA)   # SEL high
        a.b(0xAD, 0x00, 0x10, 0x29, 0x0F, 0x0A, 0x0A, 0x0A, 0x0A, 0x85, 0x20)  # the directions, << 4, to $20
        a.b(0x9C, 0x00, 0x10, 0xEA, 0xEA)               # SEL low
        a.b(0xAD, 0x00, 0x10, 0x29, 0x0F, 0x05, 0x20, 0x49, 0xFF, 0x95, 0x10 + 8 * n)  # | buttons, inverted, to $10,X
        a.b(0xE8, 0xE0, 0x05)                           # INX; CPX #5
        a.br(0xD0, "pads%d" % n)
    a.b(0xE6, 0x00)                                 # INC $00
    a.b(0x9C, 0x02, 0x04, 0x9C, 0x03, 0x04)         # VCE colour 0
    a.b(0xA5, 0x10, 0x8D, 0x04, 0x04, 0x9C, 0x05, 0x04)   # = pad 1's byte
    a.b(0xA5, 0x10, 0x8D, 0x02, 0x08, 0xA9, 0x01, 0x8D, 0x03, 0x08)  # channel 0's frequency
    a.jmp("main")
    a.label("rti")
    a.b(0x40)
    return a.resolve(), a.labels


def cart(passes=1):
    code, labels = program(passes)
    rom = bytearray(0x2000)
    rom[0:len(code)] = code
    for vec in (0x1FF6, 0x1FF8, 0x1FFA, 0x1FFC):
        rom[vec:vec + 2] = labels["rti"].to_bytes(2, "little")
    rom[0x1FFE:0x2000] = labels["reset"].to_bytes(2, "little")
    return bytes(rom)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data = cart()
    for name in ("pce-test.pce", "sgx-test.sgx"):
        with open(os.path.join(sys.argv[1], name), "wb") as f:
            f.write(data)
    with open(os.path.join(sys.argv[1], "pce-pad6.pce"), "wb") as f:
        f.write(cart(2))


if __name__ == "__main__":
    main()

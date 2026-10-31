#!/usr/bin/env python3
"""Builds the input test cartridge this repository uses: a small NES program
that shows what the controller ports hold in its RAM, for the Four Score,
the Zapper and the Arkanoid controller as for a pad.

Usage: make-input-test.py <out dir>

Writes input-test.nes (mapper 0, 16 KiB of program, 8 KiB of CHR RAM).

What the program does, after the two vertical blanks a console needs to
settle:
  - it draws the right half of the screen white and the left half black
    (one tile of colour 1 and one of colour 0 in CHR RAM, the backdrop
    black), so a Zapper pointed at the right half sees light and one
    pointed at the left half does not;
  - each frame (NMI) it counts frames in RAM $00, strobes the ports and
    keeps the next 24 reads of $4016 in RAM $10-$27 and the next 24 of
    $4017 in RAM $30-$47, whole bytes as read. A pad's buttons are bit 0
    of the first 8; the Four Score's are bit 0 of all 24 (players 1 and 3
    on $4016, 2 and 4 on $4017, then its signature); the Zapper's trigger
    is bit 4 and its light bit 3 of $4017; the Arkanoid controller's knob
    is bit 4 of the first 8 reads of $4017, inverted, highest bit first,
    and its button bit 3;
  - between two NMIs it reads $4017 as fast as it can, counting the reads,
    until bit 3 is 0 (for a Zapper: it sees light). RAM $52 is 1 when that
    happened in the frame, and $53/$54 how many reads it took, which grows
    with how far down the screen the Zapper points.

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import sys

OPS = {
    "SEI": {"imp": 0x78}, "CLD": {"imp": 0xD8}, "TXS": {"imp": 0x9A}, "RTI": {"imp": 0x40},
    "PHA": {"imp": 0x48}, "PLA": {"imp": 0x68}, "TXA": {"imp": 0x8A}, "TAX": {"imp": 0xAA},
    "INX": {"imp": 0xE8}, "DEX": {"imp": 0xCA}, "DEY": {"imp": 0x88},
    "LDA": {"imm": 0xA9, "zp": 0xA5, "abs": 0xAD},
    "LDX": {"imm": 0xA2},
    "LDY": {"imm": 0xA0},
    "STA": {"zp": 0x85, "abs": 0x8D, "zpx": 0x95},
    "INC": {"zp": 0xE6},
    "AND": {"imm": 0x29},
    "CPX": {"imm": 0xE0},
    "BIT": {"abs": 0x2C},
    "JMP": {"abs": 0x4C},
    "BPL": {"rel": 0x10}, "BNE": {"rel": 0xD0}, "BEQ": {"rel": 0xF0},
}
SIZE = {"imp": 1, "imm": 2, "zp": 2, "zpx": 2, "abs": 3, "rel": 2}


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.items = []
        self.labels = {}

    def label(self, name):
        self.items.append(("label", name))

    def op(self, name, mode="imp", arg=None):
        assert mode in OPS[name], (name, mode)
        self.items.append(("op", name, mode, arg))

    def assemble(self):
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                self.labels[it[1]] = pc
            else:
                pc += SIZE[it[2]]
        out = bytearray()
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                continue
            _, name, mode, arg = it
            code = OPS[name][mode]
            if isinstance(arg, str):
                arg = self.labels[arg]
            if mode == "imp":
                out.append(code)
            elif mode in ("imm", "zp", "zpx"):
                out += bytes([code, arg & 0xFF])
            elif mode == "abs":
                out += bytes([code, arg & 0xFF, arg >> 8])
            elif mode == "rel":
                off = arg - (pc + 2)
                assert -128 <= off <= 127, (name, off)
                out += bytes([code, off & 0xFF])
            pc += SIZE[mode]
        return bytes(out)


def ppu_addr(a, addr):
    a.op("LDA", "imm", addr >> 8)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "imm", addr & 0xFF)
    a.op("STA", "abs", 0x2006)


def program():
    a = Asm(0xC000)
    a.label("reset")
    a.op("SEI")
    a.op("CLD")
    a.op("LDX", "imm", 0xFF)
    a.op("TXS")
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2000)
    a.op("STA", "abs", 0x2001)
    a.op("LDA", "imm", 0x40)
    a.op("STA", "abs", 0x4017)  # no APU frame IRQ
    for wait in ("vb1", "vb2"):
        a.label(wait)
        a.op("BIT", "abs", 0x2002)
        a.op("BPL", "rel", wait)

    # CHR RAM tile 1 ($0010-$001F): colour 1 everywhere; tile 0 stays 0
    ppu_addr(a, 0x0010)
    a.op("LDX", "imm", 8)
    a.op("LDA", "imm", 0xFF)
    a.label("plane0")
    a.op("STA", "abs", 0x2007)
    a.op("DEX")
    a.op("BNE", "rel", "plane0")
    a.op("LDX", "imm", 8)
    a.op("LDA", "imm", 0x00)
    a.label("plane1")
    a.op("STA", "abs", 0x2007)
    a.op("DEX")
    a.op("BNE", "rel", "plane1")

    # nametable 0: 30 rows of 16 black tiles then 16 white ones; then the
    # attribute table, all palette 0
    ppu_addr(a, 0x2000)
    a.op("LDY", "imm", 30)
    a.label("row")
    a.op("LDX", "imm", 16)
    a.op("LDA", "imm", 0)
    a.label("left")
    a.op("STA", "abs", 0x2007)
    a.op("DEX")
    a.op("BNE", "rel", "left")
    a.op("LDX", "imm", 16)
    a.op("LDA", "imm", 1)
    a.label("right")
    a.op("STA", "abs", 0x2007)
    a.op("DEX")
    a.op("BNE", "rel", "right")
    a.op("DEY")
    a.op("BNE", "rel", "row")
    a.op("LDX", "imm", 64)
    a.op("LDA", "imm", 0)
    a.label("attr")
    a.op("STA", "abs", 0x2007)
    a.op("DEX")
    a.op("BNE", "rel", "attr")

    # palette: backdrop black ($0F), colour 1 white ($30)
    ppu_addr(a, 0x3F00)
    a.op("LDA", "imm", 0x0F)
    a.op("STA", "abs", 0x2007)
    a.op("LDA", "imm", 0x30)
    a.op("STA", "abs", 0x2007)

    a.op("LDA", "imm", 0)
    for zp in (0x00, 0x01, 0x52, 0x53, 0x54):
        a.op("STA", "zp", zp)
    a.op("STA", "abs", 0x2005)
    a.op("STA", "abs", 0x2005)
    a.op("LDA", "imm", 0x80)  # NMI on, nametable 0, tiles from $0000
    a.op("STA", "abs", 0x2000)
    a.op("LDA", "imm", 0x0A)  # background on, left column too
    a.op("STA", "abs", 0x2001)

    # between NMIs: read $4017 until bit 3 is 0, counting the reads
    a.label("wait")
    a.op("LDA", "zp", 0x01)
    a.op("BEQ", "rel", "wait")
    a.label("frame")
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x01)
    a.op("STA", "zp", 0x50)
    a.op("STA", "zp", 0x51)
    a.label("poll")
    a.op("INC", "zp", 0x50)
    a.op("BNE", "rel", "nocarry")
    a.op("INC", "zp", 0x51)
    a.label("nocarry")
    a.op("LDA", "abs", 0x4017)
    a.op("AND", "imm", 0x08)
    a.op("BEQ", "rel", "found")
    a.op("LDA", "zp", 0x01)
    a.op("BEQ", "rel", "poll")
    # the next frame began with no light seen
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x52)
    a.op("STA", "zp", 0x53)
    a.op("STA", "zp", 0x54)
    a.op("JMP", "abs", "frame")
    a.label("found")
    a.op("LDA", "imm", 1)
    a.op("STA", "zp", 0x52)
    a.op("LDA", "zp", 0x50)
    a.op("STA", "zp", 0x53)
    a.op("LDA", "zp", 0x51)
    a.op("STA", "zp", 0x54)
    a.op("JMP", "abs", "wait")

    # NMI: count the frame, strobe, keep 24 reads of each port
    a.label("nmi")
    a.op("PHA")
    a.op("TXA")
    a.op("PHA")
    a.op("INC", "zp", 0x00)
    a.op("LDA", "imm", 1)
    a.op("STA", "abs", 0x4016)
    a.op("LDA", "imm", 0)
    a.op("STA", "abs", 0x4016)
    a.op("LDX", "imm", 0)
    a.label("read4016")
    a.op("LDA", "abs", 0x4016)
    a.op("STA", "zpx", 0x10)
    a.op("INX")
    a.op("CPX", "imm", 24)
    a.op("BNE", "rel", "read4016")
    a.op("LDX", "imm", 0)
    a.label("read4017")
    a.op("LDA", "abs", 0x4017)
    a.op("STA", "zpx", 0x30)
    a.op("INX")
    a.op("CPX", "imm", 24)
    a.op("BNE", "rel", "read4017")
    a.op("LDA", "imm", 1)
    a.op("STA", "zp", 0x01)
    a.op("PLA")
    a.op("TAX")
    a.op("PLA")
    a.label("irq")
    a.op("RTI")

    code = a.assemble()
    prg = bytearray(code + bytes(0x4000 - 6 - len(code)))
    for name in ("nmi", "reset", "irq"):
        v = a.labels[name]
        prg += bytes([v & 0xFF, v >> 8])
    assert len(prg) == 0x4000
    return bytes(prg)


def header():
    h = bytearray(16)
    h[0:4] = b"NES\x1a"
    h[4] = 1      # 16 KiB PRG ROM
    h[5] = 0      # no CHR ROM
    h[6] = 0x00   # mapper 0, horizontal mirroring
    h[7] = 0x08   # NES 2.0
    h[11] = 0x07  # 8 KiB CHR RAM
    return bytes(h)


def main():
    with open(os.path.join(sys.argv[1], "input-test.nes"), "wb") as f:
        f.write(header() + program())


if __name__ == "__main__":
    main()

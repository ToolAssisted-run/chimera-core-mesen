#!/usr/bin/env python3
"""Builds the NES device test cartridges this repository uses: one small NES
program that, each frame, talks to the controller ports the way one device
needs (a list of writes to $4016 and reads of $4016, $4017 or $6000) and
keeps every byte it reads in its RAM.

Usage: make-nes-devices.py <out dir>

Writes one cartridge per way of talking (mapper 0, 16 KiB of program, 8 KiB
of CHR RAM; the microphone's on mapper 188, the Bandai Karaoke Studio's):

  nes-serial.nes    strobe, 32 reads of $4016, 32 of $4017; three times
                    (a mouse that sends three bytes takes three strobes):
                    the Subor mouse, the Virtual Boy controller, a Super
                    NES controller, mouse or NTT Data Keypad in an NES port,
                    the Famicom's second controller (its microphone), the
                    two-player adapter, the Pachinko controller, the FCNS
                    keypad, the Hori Track, Bandai's Hyper Shot
  nes-oeka.nes      the Oeka Kids tablet: $4016 = 0 (the pen's place is
                    taken), 1, then 18 times $4016 = 3 (the next bit), a
                    read of $4017, $4016 = 1, a read of $4017
  nes-boxing.nes    the Exciting Boxing bag: $4016 = 0, a read of $4017,
                    $4016 = 2, a read of $4017 (its two sets of sensors)
  nes-mahjong.nes   the Jissen Mahjong controller: for rows 1, 2 and 3,
                    $4016 = row * 2 + 1, then row * 2, then 8 reads of $4017
  nes-fbkey.nes     the Family BASIC keyboard: $4016 = 5 (row 0, on), a
                    read of $4017, then nine times $4016 = 6 (the other
                    four columns), a read, $4016 = 4 (the next row), a read;
                    then $4016 = 6 and a read: the ten rows' two halves
  nes-suborkey.nes  the Subor keyboard: $4016 = 5, 4 (row 0), then
                    thirteen times a read of $4017, $4016 = 6, a read,
                    $4016 = 4 (the next row): the thirteen rows' two halves
  nes-mic.nes       mapper 188: a read of $6000, where the Bandai
                    microphone's buttons answer
  nes-dmc.nes       the console type's test: the sound chip's sample
                    channel (DMC) plays a looping one-byte sample ($FF, at
                    $FF00) at its fastest rate while the program strobes and
                    reads $4016 eight times, forty times over (unrolled,
                    so that fetches land on the reads), keeping all run
                    long the bits any read had (RAM $10) and how many groups
                    of eight read otherwise than the frame's first ($11,
                    counting on). A DMC fetch
                    that lands on a read of $4016 makes the CPU read it
                    twice in a row: Mesen hands the controller both reads
                    (a bit lost) only on the Famicom HVC-001
                    (NesControlManager::ReadDevice); and the read after the
                    fetch finds the fetched $FF on the bus, of which each
                    console type passes its own bits (the open bus mask:
                    $E0 on the NES-001, $E4 on the NES-101, $F8 on the
                    Famicoms)

What the program keeps (every cartridge):
  - RAM $00 counts frames; the bytes it reads, in order, from RAM $0200
    (up to 256 of them a frame; nes-dmc.nes's 320 go on into $0300);
  - the right half of the screen is white and the left half black, as on
    the input test cartridge, so a light gun pointed right sees light;
  - nes-serial.nes also reads $4017 as fast as it can between frames until
    bit 3 is 0 (a light gun sees light), as the input test cartridge does:
    RAM $52 is 1 when that happened in the frame, and $53/$54 how many
    reads it took.

This is our own program, written for this repository's tests; it is under
the repository's licence.
"""
import os
import sys

# the opcodes used, by mnemonic and addressing mode
OPS = {
    ("SEI", "imp"): 0x78, ("CLD", "imp"): 0xD8, ("TXS", "imp"): 0x9A, ("RTI", "imp"): 0x40,
    ("PHA", "imp"): 0x48, ("PLA", "imp"): 0x68, ("TXA", "imp"): 0x8A, ("TAX", "imp"): 0xAA,
    ("TYA", "imp"): 0x98, ("TAY", "imp"): 0xA8, ("INX", "imp"): 0xE8, ("INY", "imp"): 0xC8,
    ("DEX", "imp"): 0xCA, ("DEY", "imp"): 0x88, ("CLC", "imp"): 0x18,
    ("LDA", "imm"): 0xA9, ("LDA", "zp"): 0xA5, ("LDA", "abs"): 0xAD, ("LDA", "indy"): 0xB1, ("LDA", "absy"): 0xB9,
    ("STA", "indy"): 0x91,
    ("LDX", "imm"): 0xA2, ("LDY", "imm"): 0xA0,
    ("STA", "zp"): 0x85, ("STA", "abs"): 0x8D, ("STA", "absx"): 0x9D, ("STA", "absy"): 0x99,
    ("INC", "zp"): 0xE6, ("DEC", "zp"): 0xC6,
    ("AND", "imm"): 0x29, ("CMP", "imm"): 0xC9, ("CPX", "imm"): 0xE0, ("ORA", "zp"): 0x05,
    ("CMP", "zp"): 0xC5, ("LSR", "imp"): 0x4A, ("ROL", "zp"): 0x26,
    ("BIT", "abs"): 0x2C, ("JMP", "abs"): 0x4C,
    ("BPL", "rel"): 0x10, ("BNE", "rel"): 0xD0, ("BEQ", "rel"): 0xF0, ("BCC", "rel"): 0x90,
}
SIZE = {"imp": 1, "imm": 2, "zp": 2, "indy": 2, "abs": 3, "absx": 3, "absy": 3, "rel": 2}


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.items = []
        self.labels = {}

    def label(self, name):
        self.items.append(("label", name))

    def op(self, name, mode="imp", arg=None):
        assert (name, mode) in OPS, (name, mode)
        self.items.append(("op", name, mode, arg))

    def data(self, data):
        self.items.append(("data", bytes(data)))

    def assemble(self):
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                self.labels[it[1]] = pc
            elif it[0] == "data":
                pc += len(it[1])
            else:
                pc += SIZE[it[2]]
        out = bytearray()
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                continue
            if it[0] == "data":
                out += it[1]
                pc += len(it[1])
                continue
            _, name, mode, arg = it
            code = OPS[(name, mode)]
            if isinstance(arg, str):
                arg = self.labels[arg]
            if mode == "imp":
                out.append(code)
            elif mode in ("imm", "zp", "indy"):
                out += bytes([code, arg & 0xFF])
            elif mode in ("abs", "absx", "absy"):
                out += bytes([code, arg & 0xFF, arg >> 8])
            elif mode == "rel":
                off = arg - (pc + 2)
                assert -128 <= off <= 127, (name, off)
                out += bytes([code, off & 0xFF])
            pc += SIZE[mode]
        return bytes(out)


# the script's operations: a byte, then its argument
END, WRITE, READ4016, READ4017, READ6000 = 0, 1, 2, 3, 5


def w(v):
    return [WRITE, v]


def r16(n):
    return [READ4016, n]


def r17(n):
    return [READ4017, n]


SCRIPTS = {
    "nes-serial": (w(1) + w(0) + r16(32) + r17(32)) * 3,
    "nes-oeka": w(0) + w(1) + (w(3) + r17(1) + w(1) + r17(1)) * 18,
    "nes-boxing": w(0) + r17(1) + w(2) + r17(1),
    "nes-mahjong": sum((w(row * 2 + 1) + w(row * 2) + r17(8) for row in (1, 2, 3)), []),
    "nes-fbkey": w(5) + r17(1) + (w(6) + r17(1) + w(4) + r17(1)) * 9 + w(6) + r17(1),
    "nes-suborkey": w(5) + w(4) + (r17(1) + w(6) + r17(1) + w(4)) * 13,
    "nes-mic": [READ6000, 1],
    "nes-dmc": [],  # its reads are unrolled in the program (below)
}


def ppu_addr(a, addr):
    a.op("LDA", "imm", addr >> 8)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "imm", addr & 0xFF)
    a.op("STA", "abs", 0x2006)


def program(name):
    script = SCRIPTS[name] + [END]
    assert len(script) <= 255, (name, len(script))
    light = name == "nes-serial"
    dmc = name == "nes-dmc"
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

    # CHR RAM tile 1: colour 1 everywhere; tile 0 stays 0
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
    # the nametable: 30 rows of 16 black tiles then 16 white; attributes 0
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
    # the palette: backdrop black, colour 1 white
    ppu_addr(a, 0x3F00)
    a.op("LDA", "imm", 0x0F)
    a.op("STA", "abs", 0x2007)
    a.op("LDA", "imm", 0x30)
    a.op("STA", "abs", 0x2007)

    a.op("LDA", "imm", 0)
    for zp in (0x00, 0x01, 0x10, 0x11, 0x52, 0x53, 0x54):
        a.op("STA", "zp", zp)
    a.op("STA", "abs", 0x2005)
    a.op("STA", "abs", 0x2005)
    if dmc:
        # the sample channel: rate 15 (the fastest), looping, a 1-byte
        # sample at $FF00 (a byte $FF), started
        a.op("LDA", "imm", 0x4F)
        a.op("STA", "abs", 0x4010)
        a.op("LDA", "imm", 0xFC)
        a.op("STA", "abs", 0x4012)
        a.op("LDA", "imm", 0x00)
        a.op("STA", "abs", 0x4013)
        a.op("LDA", "imm", 0x10)
        a.op("STA", "abs", 0x4015)
    a.op("LDA", "imm", 0x80)  # NMI on
    a.op("STA", "abs", 0x2000)
    a.op("LDA", "imm", 0x0A)  # background on, left column too
    a.op("STA", "abs", 0x2001)

    a.label("wait")
    a.op("LDA", "zp", 0x01)
    a.op("BEQ", "rel", "wait")
    a.label("frame")
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x01)
    if light:
        # between frames: read $4017 until bit 3 is 0, counting the reads
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

    # NMI: count the frame, then run the script; X counts the bytes read
    # (into $0200 and on), Y walks the script, $06 counts a read's repeats
    a.label("nmi")
    a.op("PHA")
    a.op("TXA")
    a.op("PHA")
    a.op("TYA")
    a.op("PHA")
    a.op("INC", "zp", 0x00)
    if dmc:
        # unrolled: a strobe, then eight reads of $4016 each kept at once
        # (LDA $4016; STA $02xx/$03xx), forty times: a read of $4016 every
        # 8 cycles, so the sample channel's fetches land on some of them
        for k in range(40):
            a.op("LDA", "imm", 1)
            a.op("STA", "abs", 0x4016)
            a.op("LDA", "imm", 0)
            a.op("STA", "abs", 0x4016)
            for b in range(8):
                a.op("LDA", "abs", 0x4016)
                a.op("STA", "abs", 0x0200 + k * 8 + b)
                a.op("ORA", "zp", 0x10)
                a.op("STA", "zp", 0x10)   # every bit any read had, the whole run
                a.op("LDA", "abs", 0x0200 + k * 8 + b)
                a.op("LSR")
                a.op("ROL", "zp", 0x12)   # the group's eight data bits
            a.op("LDA", "zp", 0x12)
            if k == 0:
                a.op("STA", "zp", 0x13)   # the frame's first group: the pad
            else:
                a.op("CMP", "zp", 0x13)
                a.op("BEQ", "rel", "same%d" % k)
                a.op("INC", "zp", 0x11)   # a group that read otherwise: a bit lost
                a.label("same%d" % k)
        a.op("JMP", "abs", "done")
    a.op("LDA", "imm", 0x00)
    a.op("STA", "zp", 0x04)  # where the next byte read goes: $0200
    a.op("LDA", "imm", 0x02)
    a.op("STA", "zp", 0x05)
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x07)  # bytes kept so far (low byte), X's copy
    a.op("LDY", "imm", 0)
    a.label("next")
    a.op("LDA", "absy", "script")
    a.op("INY")
    a.op("CMP", "imm", END)
    a.op("BNE", "rel", "more")
    a.op("JMP", "abs", "done")
    a.label("more")
    a.op("TAX")
    a.op("LDA", "absy", "script")
    a.op("INY")
    a.op("CPX", "imm", WRITE)
    a.op("BNE", "rel", "isread")
    a.op("STA", "abs", 0x4016)
    a.op("JMP", "abs", "next")
    a.label("isread")
    a.op("STA", "zp", 0x06)
    for op, addr in ((READ4016, 0x4016), (READ4017, 0x4017), (READ6000, 0x6000)):
        lab = "read%04x" % addr
        skip = "not%04x" % addr
        a.op("CPX", "imm", op)
        a.op("BNE", "rel", skip)
        a.label(lab)
        a.op("LDA", "abs", addr)
        a.op("JMP", "abs", "keep%04x" % addr)
        a.label("back%04x" % addr)
        a.op("DEC", "zp", 0x06)
        a.op("BNE", "rel", lab)
        a.op("JMP", "abs", "next")
        a.label(skip)
    a.op("JMP", "abs", "next")
    # keep the byte in A at ($04), then move on (to the next page at the end
    # of one)
    for addr in (0x4016, 0x4017, 0x6000):
        a.label("keep%04x" % addr)
        a.op("TAX")
        a.op("TYA")
        a.op("PHA")
        a.op("TXA")
        a.op("LDY", "imm", 0)
        a.op("STA", "indy", 0x04)
        a.op("INC", "zp", 0x04)
        a.op("BNE", "rel", "same%04x" % addr)
        a.op("INC", "zp", 0x05)
        a.label("same%04x" % addr)
        a.op("PLA")
        a.op("TAY")
        a.op("JMP", "abs", "back%04x" % addr)
    a.label("done")
    a.op("LDA", "imm", 1)
    a.op("STA", "zp", 0x01)
    a.op("PLA")
    a.op("TAY")
    a.op("PLA")
    a.op("TAX")
    a.op("PLA")
    a.label("irq")
    a.op("RTI")
    a.label("script")
    a.data(script)

    code = a.assemble()
    prg = bytearray(code + bytes(0x4000 - 6 - len(code)))
    assert len(code) < 0x3F00
    prg[0x3F00] = 0xFF  # nes-dmc.nes's sample
    for vec in ("nmi", "reset", "irq"):
        v = a.labels[vec]
        prg += bytes([v & 0xFF, v >> 8])
    assert len(prg) == 0x4000
    return bytes(prg)


def header(mapper):
    h = bytearray(16)
    h[0:4] = b"NES\x1a"
    h[4] = 1      # 16 KiB PRG ROM
    h[5] = 0      # no CHR ROM
    h[6] = ((mapper & 0x0F) << 4) | 0x00  # horizontal mirroring
    h[7] = (mapper & 0xF0) | 0x08         # NES 2.0
    h[11] = 0x07  # 8 KiB CHR RAM
    return bytes(h)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for name in SCRIPTS:
        with open(os.path.join(sys.argv[1], name + ".nes"), "wb") as f:
            f.write(header(188 if name == "nes-mic" else 0) + program(name))


if __name__ == "__main__":
    main()

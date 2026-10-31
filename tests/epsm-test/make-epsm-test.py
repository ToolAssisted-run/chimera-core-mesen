#!/usr/bin/env python3
"""Builds the EPSM test cartridge this repository uses: a small NES program
that plays the EPSM's three kinds of sound and lets the first pad change them.

Usage: make-epsm-test.py <out dir>

Writes three files:
    epsm-test.nes     NES 2.0 header saying "a console with the EPSM"
                      (byte 7 console type 3, byte 13 extended type 4), so
                      Mesen plugs the EPSM in;
    epsm-absent.nes   the same program with a plain NES 2.0 header;
    epsm-no4016.nes   the EPSM header, and the program's writes through
                      $4016 made with OUT1 held low, so they never reach the
                      chip (the control for the $4016 way of writing it).

What the program does, after the two vertical blanks a console needs to
settle:
  - the SSG (the YMF288's three square-wave channels): channel A at a
    steady tone, written through $401C/$401D; channel B at another, written
    through $4016 (the EPSM's other way in: OUT1's rising edge latches the
    high nibble and the port, its falling edge the low nibble and writes);
  - the chip's timer A, raising the CPU's IRQ; the IRQ handler counts in
    RAM $02 and acknowledges the timer, so the chip reaches the machine;
  - FM channel 1: one carrier operator holding a note;
  - the rhythm part (ADPCM-A): a bass drum struck every 32 frames, and a
    snare every 64. Its sounds come from the chip's own rhythm ROM, which
    the user brings as firmware (ymf288_adpcm_rom.bin); with no ROM Mesen
    plays zeros there and the drums are silent.
  - each frame (NMI) it reads pad 1 into RAM $01, counts frames in RAM $00,
    and makes pad 1 change the FM note (the pad's byte is the low part of
    the note's frequency), so input reaches both the machine's RAM and the
    EPSM.
The picture is the backdrop colour, which also follows pad 1.

The EPSM is written through $401C (address, registers 0x00-0xFF of the
first half), $401D (data), $401E and $401F (the second half), as Mesen
connects it. This is our own program, written for this repository's tests;
it is under the repository's licence.
"""
import os
import sys

# ---------------------------------------------------------------- assembler
OPS = {
    # name: {mode: opcode}
    "SEI": {"imp": 0x78}, "CLI": {"imp": 0x58}, "CLD": {"imp": 0xD8}, "TXS": {"imp": 0x9A},
    "RTI": {"imp": 0x40}, "PHA": {"imp": 0x48}, "PLA": {"imp": 0x68},
    "TXA": {"imp": 0x8A}, "TAX": {"imp": 0xAA}, "TYA": {"imp": 0x98},
    "TAY": {"imp": 0xA8}, "INX": {"imp": 0xE8}, "DEX": {"imp": 0xCA},
    "INY": {"imp": 0xC8}, "DEY": {"imp": 0x88}, "RTS": {"imp": 0x60},
    "LSR": {"acc": 0x4A, "zp": 0x46},
    "ROL": {"zp": 0x26},
    "LDA": {"imm": 0xA9, "zp": 0xA5, "abs": 0xAD, "absx": 0xBD},
    "LDX": {"imm": 0xA2, "zp": 0xA6},
    "LDY": {"imm": 0xA0},
    "STA": {"zp": 0x85, "abs": 0x8D},
    "STX": {"zp": 0x86, "abs": 0x8E},
    "INC": {"zp": 0xE6},
    "AND": {"imm": 0x29},
    "EOR": {"imm": 0x49, "zp": 0x45},
    "CMP": {"imm": 0xC9},
    "CPX": {"imm": 0xE0},
    "BIT": {"abs": 0x2C},
    "JMP": {"abs": 0x4C},
    "JSR": {"abs": 0x20},
    "BPL": {"rel": 0x10}, "BMI": {"rel": 0x30}, "BNE": {"rel": 0xD0},
    "BEQ": {"rel": 0xF0}, "BCC": {"rel": 0x90}, "BCS": {"rel": 0xB0},
}
SIZE = {"imp": 1, "acc": 1, "imm": 2, "zp": 2, "abs": 3, "absx": 3, "rel": 2}


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.items = []  # (kind, ...)
        self.labels = {}

    def label(self, name):
        self.items.append(("label", name))

    def op(self, name, mode="imp", arg=None):
        assert mode in OPS[name], (name, mode)
        self.items.append(("op", name, mode, arg))

    def byte(self, *values):
        self.items.append(("bytes", bytes(values)))

    def assemble(self):
        # pass 1: addresses
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                self.labels[it[1]] = pc
            elif it[0] == "op":
                pc += SIZE[it[2]]
            else:
                pc += len(it[1])
        # pass 2: bytes
        out = bytearray()
        pc = self.origin
        for it in self.items:
            if it[0] == "label":
                continue
            if it[0] == "bytes":
                out += it[1]
                pc += len(it[1])
                continue
            _, name, mode, arg = it
            code = OPS[name][mode]
            if isinstance(arg, str):
                arg = self.labels[arg]
            if mode in ("imp", "acc"):
                out.append(code)
            elif mode in ("imm", "zp"):
                out += bytes([code, arg & 0xFF])
            elif mode in ("abs", "absx"):
                out += bytes([code, arg & 0xFF, arg >> 8])
            elif mode == "rel":
                off = arg - (pc + 2)
                assert -128 <= off <= 127, (name, off)
                out += bytes([code, off & 0xFF])
            pc += SIZE[mode]
        return bytes(out)


# ---------------------------------------------------------------- program
def opn(a, reg, value, part=0):
    """write one EPSM register: part 0 through $401C/$401D, part 1 $401E/$401F"""
    base = 0x401C + 2 * part
    a.op("LDA", "imm", reg)
    a.op("STA", "abs", base)
    a.op("LDA", "imm", value)
    a.op("STA", "abs", base + 1)


def opn4016(a, port, value, live):
    """one byte to the EPSM through $4016: port 0 = address, 1 = data (first
    half). Two writes: OUT1 (bit 1) high with the high nibble and the port in
    bits 2-3, then OUT1 low with the low nibble. With live False OUT1 never
    rises and the chip is not written."""
    out1 = 0x02 if live else 0x00
    first = (value & 0xF0) | out1 | ((port >> 1) & 1) << 2 | (port & 1) << 3
    second = (value & 0x0F) << 4
    a.op("LDA", "imm", first)
    a.op("STA", "abs", 0x4016)
    a.op("LDA", "imm", second)
    a.op("STA", "abs", 0x4016)


def opn_via_4016(a, reg, value, live):
    opn4016(a, 0, reg, live)
    opn4016(a, 1, value, live)


def program(live4016=True):
    a = Asm(0xC000)
    a.label("reset")
    a.op("SEI")
    a.op("CLD")
    a.op("LDX", "imm", 0xFF)
    a.op("TXS")
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2000)  # NMI off while setting up
    a.op("STA", "abs", 0x2001)  # rendering off
    a.op("LDA", "imm", 0x40)
    a.op("STA", "abs", 0x4017)  # the APU's frame IRQ off: the only IRQ is the chip's
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x4010)  # and the DMC's off
    for wait in ("vb1", "vb2"):
        a.label(wait)
        a.op("BIT", "abs", 0x2002)
        a.op("BPL", "rel", wait)
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x00)
    a.op("STA", "zp", 0x01)

    # SSG channel A: a steady tone
    opn(a, 0x00, 0xFE)
    opn(a, 0x01, 0x00)
    opn(a, 0x07, 0x3C)  # tones A and B on, everything else off (active low)
    opn(a, 0x08, 0x0C)  # channel A volume
    # SSG channel B through $4016
    opn_via_4016(a, 0x02, 0x80, live4016)
    opn_via_4016(a, 0x03, 0x01, live4016)
    opn_via_4016(a, 0x09, 0x0A, live4016)
    # FM channel 1: algorithm 7, only operator 1 sounding
    opn(a, 0xB0, 0x07)
    opn(a, 0xB4, 0xC0)
    for slot in (0x30, 0x34, 0x38, 0x3C):
        opn(a, slot, 0x01)  # DT 0, MUL 1
    opn(a, 0x40, 0x10)      # operator 1 total level (loud)
    for slot in (0x44, 0x48, 0x4C):
        opn(a, slot, 0x7F)  # the other three silent
    for slot in (0x50, 0x54, 0x58, 0x5C):
        opn(a, slot, 0x1F)  # attack rate max
    for slot in (0x60, 0x64, 0x68, 0x6C, 0x70, 0x74, 0x78, 0x7C):
        opn(a, slot, 0x00)  # no decay
    for slot in (0x80, 0x84, 0x88, 0x8C):
        opn(a, slot, 0x0F)  # sustain level 0, release fast
    opn(a, 0xA4, 0x22)      # block 4, F-number high bits
    opn(a, 0xA0, 0x69)
    opn(a, 0x28, 0xF0)      # key on, channel 1, all four operators
    # rhythm: total level, then each drum's level and both speakers
    opn(a, 0x11, 0x3F)
    for reg in range(0x18, 0x1E):
        opn(a, reg, 0xDF)

    # timer A: period, then load it with its IRQ enabled
    opn(a, 0x24, 0x80)
    opn(a, 0x25, 0x00)
    opn(a, 0x27, 0x05)
    a.op("LDA", "imm", 0)
    a.op("STA", "zp", 0x02)

    # backdrop colour, then NMI on and rendering on
    a.op("LDA", "imm", 0x3F)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "imm", 0x11)
    a.op("STA", "abs", 0x2007)
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2005)
    a.op("STA", "abs", 0x2005)
    a.op("LDA", "imm", 0x80)
    a.op("STA", "abs", 0x2000)
    a.op("LDA", "imm", 0x0A)
    a.op("STA", "abs", 0x2001)
    a.op("CLI")
    a.label("forever")
    a.op("JMP", "abs", "forever")

    # NMI: count the frame, read pad 1, drive the EPSM from it
    a.label("nmi")
    a.op("PHA")
    a.op("INC", "zp", 0x00)
    a.op("LDA", "imm", 0x01)  # strobe the pads (bit 1 stays 0: no EPSM write)
    a.op("STA", "abs", 0x4016)
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x4016)
    a.op("LDX", "imm", 8)
    a.label("readpad")
    a.op("LDA", "abs", 0x4016)
    a.op("LSR", "acc")
    a.op("ROL", "zp", 0x01)
    a.op("DEX")
    a.op("BNE", "rel", "readpad")
    # the pad's byte is the FM note's low frequency bits
    a.op("LDA", "imm", 0xA0)
    a.op("STA", "abs", 0x401C)
    a.op("LDA", "zp", 0x01)
    a.op("EOR", "imm", 0x69)
    a.op("STA", "abs", 0x401D)
    # and the backdrop colour
    a.op("LDA", "imm", 0x3F)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2006)
    a.op("LDA", "zp", 0x01)
    a.op("AND", "imm", 0x3F)
    a.op("STA", "abs", 0x2007)
    a.op("LDA", "imm", 0x00)
    a.op("STA", "abs", 0x2005)
    a.op("STA", "abs", 0x2005)
    # every 32 frames a bass drum, every 64 a snare too
    a.op("LDA", "zp", 0x00)
    a.op("AND", "imm", 0x1F)
    a.op("BNE", "rel", "nodrum")
    a.op("LDA", "imm", 0x10)
    a.op("STA", "abs", 0x401C)
    a.op("LDA", "zp", 0x00)
    a.op("AND", "imm", 0x20)
    a.op("BEQ", "rel", "bassonly")
    a.op("LDA", "imm", 0x03)  # bass drum + snare
    a.op("JMP", "abs", "keyon")
    a.label("bassonly")
    a.op("LDA", "imm", 0x01)  # bass drum
    a.label("keyon")
    a.op("STA", "abs", 0x401D)
    a.label("nodrum")
    a.op("PLA")
    a.op("RTI")

    # IRQ: the chip's timer A. Count it, and acknowledge it (reset A's flag,
    # keep the timer loaded with its IRQ enabled).
    a.label("irq")
    a.op("PHA")
    a.op("INC", "zp", 0x02)
    a.op("LDA", "imm", 0x27)
    a.op("STA", "abs", 0x401C)
    a.op("LDA", "imm", 0x15)
    a.op("STA", "abs", 0x401D)
    a.op("PLA")
    a.op("RTI")

    code = a.assemble()
    prg = bytearray(code + bytes(0x4000 - 6 - len(code)))
    for name in ("nmi", "reset", "irq"):
        v = a.labels[name]
        prg += bytes([v & 0xFF, v >> 8])
    assert len(prg) == 0x4000
    return bytes(prg)


def header(epsm):
    h = bytearray(16)
    h[0:4] = b"NES\x1a"
    h[4] = 1          # 16 KiB PRG ROM
    h[5] = 0          # no CHR ROM
    h[6] = 0x00       # mapper 0
    h[7] = 0x08 | (0x03 if epsm else 0x00)  # NES 2.0; console type 3 = extended
    h[11] = 0x07      # 8 KiB CHR RAM
    h[12] = 0x00      # NTSC
    h[13] = 0x04 if epsm else 0x00          # extended console type 4 = EPSM
    return bytes(h)


def main():
    out = sys.argv[1]
    prg = program()
    with open(os.path.join(out, "epsm-test.nes"), "wb") as f:
        f.write(header(True) + prg)
    with open(os.path.join(out, "epsm-absent.nes"), "wb") as f:
        f.write(header(False) + prg)
    with open(os.path.join(out, "epsm-no4016.nes"), "wb") as f:
        f.write(header(True) + program(live4016=False))


if __name__ == "__main__":
    main()

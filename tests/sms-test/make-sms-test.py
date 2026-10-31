#!/usr/bin/env python3
"""Builds the test cartridges of Sega's 8-bit consoles and the ColecoVision
this repository uses: one small Z80 program that keeps what it reads from
the controllers in its RAM, shows and sounds it.

Usage: make-sms-test.py <out dir>

Writes sms-test.sms (Master System), gg-test.gg (Game Gear), sg-test.sg
(SG-1000) and cv-test.col (ColecoVision; it runs only with the
ColecoVision's BIOS, which starts it).

What the program does:
  - it sets the video chip up (the Master System's and Game Gear's mode 4;
    the SG-1000's and ColecoVision's TMS9918 mode, which is the same chip's
    older mode) with the display on and nothing but the backdrop, and
    turns the sound chip's (SN76489) first tone channel to full volume;
  - each frame it waits for the video chip's frame flag, reads the
    controllers and keeps them in RAM, 1 for held:
      Master System, SG-1000: the two ports' bytes ($DC and $DD, inverted)
        at RAM +0 and +1 (player 1's Up Down Left Right 1 2 on bits 0-5 of
        the first, player 2's Up and Down on bits 6-7 and the rest on bits
        0-3 of the second);
      Game Gear: the same, and the Start button ($00 bit 7) at RAM +2;
      ColecoVision: each controller read in joystick mode and in keypad
        mode ($FC and $FF), at RAM +0 to +3;
    counts frames at RAM +4, and counts the Pause button's interrupts (the
    Master System's, an NMI) at RAM +5;
  - the backdrop colour is player 1's byte, and the first tone channel
    plays at a frequency that byte gives.
RAM is at $C000 ($7000 on the ColecoVision).

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

    def org(self, addr):
        assert addr >= self.pc()
        self.out += bytes(addr - self.pc())

    def label(self, name):
        self.labels[name] = self.pc()

    def b(self, *data):
        self.out += bytes(data)

    def jr(self, op, name):
        self.b(op, 0)
        self.fix.append(("rel", len(self.out) - 1, name))

    def jp(self, name):
        self.b(0xC3, 0, 0)
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


def program(kind):
    cv = kind == "cv"
    ram = 0x7000 if cv else 0xC000
    vdp_data, vdp_ctl = 0xBE, 0xBF
    psg = 0xFF if cv else 0x7F
    origin = 0x8000 if cv else 0x0000
    a = Asm(origin)
    if cv:
        # the cartridge header the BIOS reads: $55 $AA starts the game at
        # once (no title screen); then pointers, and the start address at $800A
        a.b(0x55, 0xAA)
        a.b(0, 0, 0, 0, 0, 0, 0, 0)
        a.b(0, 0)             # $800A: the start, filled below
        a.org(0x8024)
    else:
        a.b(0xF3, 0xED, 0x56)  # DI; IM 1
        a.b(0x31, 0xF0, 0xDF)  # LD SP,$DFF0
        a.jp("start")
        a.org(0x0038)
        a.b(0xFB, 0xED, 0x4D)  # EI; RETI (no interrupt is turned on)
        a.org(0x0066)
        # the Pause button's NMI: count it
        a.b(0xF5)              # PUSH AF
        a.b(0x3A) ; a.b(*(ram + 5).to_bytes(2, "little"))   # LD A,(ram+5)
        a.b(0x3C)              # INC A
        a.b(0x32) ; a.b(*(ram + 5).to_bytes(2, "little"))   # LD (ram+5),A
        a.b(0xF1, 0xED, 0x45)  # POP AF; RETN
        a.org(0x0100)
    a.label("start")
    if cv:
        a.b(0xF3, 0x31, 0x00, 0x74)  # DI; LD SP,$7400
    # clear the RAM the program uses
    a.b(0xAF)                  # XOR A
    for i in range(8):
        a.b(0x32) ; a.b(*(ram + i).to_bytes(2, "little"))
    # the video chip's registers: value, then $80 | register
    if kind in ("sms", "gg"):
        regs = {0: 0x04, 1: 0xC0, 2: 0xFF, 5: 0xFF, 6: 0xFB, 7: 0x00}
    else:
        regs = {0: 0x00, 1: 0xC0, 2: 0x0E, 3: 0xFF, 4: 0x03, 5: 0x76, 6: 0x03, 7: 0x01}
    for r, v in regs.items():
        a.b(0x3E, v, 0xD3, vdp_ctl, 0x3E, 0x80 | r, 0xD3, vdp_ctl)
    # the first tone channel at full volume, the others silent
    for v in (0x90, 0xBF, 0xDF, 0xFF):
        a.b(0x3E, v, 0xD3, psg)
    a.label("main")
    a.label("wait")
    a.b(0xDB, vdp_ctl, 0xE6, 0x80)   # IN A,(ctl); AND $80: the frame flag
    a.jr(0x28, "wait")                # JR Z
    if cv:
        # joystick mode, then keypad mode, for each controller
        a.b(0xD3, 0xC0)                   # OUT ($C0),A: joystick mode
        a.b(0xDB, 0xFC, 0x2F, 0x32) ; a.b(*(ram + 0).to_bytes(2, "little"))
        a.b(0xDB, 0xFF, 0x2F, 0x32) ; a.b(*(ram + 1).to_bytes(2, "little"))
        a.b(0xD3, 0x80)                   # OUT ($80),A: keypad mode
        a.b(0xDB, 0xFC, 0x2F, 0x32) ; a.b(*(ram + 2).to_bytes(2, "little"))
        a.b(0xDB, 0xFF, 0x2F, 0x32) ; a.b(*(ram + 3).to_bytes(2, "little"))
    else:
        a.b(0xDB, 0xDC, 0x2F, 0x32) ; a.b(*(ram + 0).to_bytes(2, "little"))
        a.b(0xDB, 0xDD, 0x2F, 0x32) ; a.b(*(ram + 1).to_bytes(2, "little"))
        if kind == "gg":
            a.b(0xDB, 0x00, 0x2F, 0xE6, 0x80, 0x32) ; a.b(*(ram + 2).to_bytes(2, "little"))
    a.b(0x21) ; a.b(*(ram + 4).to_bytes(2, "little")) ; a.b(0x34)   # LD HL,ram+4; INC (HL)
    # the backdrop: player 1's byte
    a.b(0x3A) ; a.b(*ram.to_bytes(2, "little"))   # LD A,(ram)
    a.b(0x47)                                     # LD B,A
    if kind == "sms":
        a.b(0x3E, 0x10, 0xD3, vdp_ctl, 0x3E, 0xC0, 0xD3, vdp_ctl)   # CRAM address 16
        a.b(0x78, 0xD3, vdp_data)
    elif kind == "gg":
        a.b(0x3E, 0x20, 0xD3, vdp_ctl, 0x3E, 0xC0, 0xD3, vdp_ctl)   # CRAM address 32
        a.b(0x78, 0xD3, vdp_data, 0xD3, vdp_data)
    else:
        a.b(0x78, 0xE6, 0x0F, 0xD3, vdp_ctl, 0x3E, 0x87, 0xD3, vdp_ctl)   # register 7
    # the tone: low four bits of the byte, then the byte's top bits | 4
    a.b(0x78, 0xE6, 0x0F, 0xF6, 0x80, 0xD3, psg)          # latch channel 0, low bits
    a.b(0x78, 0x0F, 0x0F, 0x0F, 0x0F, 0xE6, 0x0F, 0xF6, 0x04, 0xD3, psg)  # RRCA x4; AND $0F; OR 4
    a.jp("main")
    code = a.resolve()
    if cv:
        code[0x0A:0x0C] = a.labels["start"].to_bytes(2, "little")
    return code


def cart(kind):
    code = program(kind)
    size = 0x8000
    rom = bytearray(size)
    rom[0:len(code)] = code
    if kind in ("sms", "gg"):
        # the header a BIOS checks: "TMR SEGA", the checksum of the first 32
        # KiB less the header, the region (4: export Master System, 7:
        # international Game Gear) and the size code (C: 32 KiB)
        rom[0x7FF0:0x7FF8] = b"TMR SEGA"
        total = sum(rom[0:0x7FF0]) & 0xFFFF
        rom[0x7FFA:0x7FFC] = total.to_bytes(2, "little")
        rom[0x7FFF] = (0x4C if kind == "sms" else 0x7C)
    return bytes(rom)


NAMES = {"sms": "sms-test.sms", "gg": "gg-test.gg", "sg": "sg-test.sg", "cv": "cv-test.col"}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for kind, name in NAMES.items():
        with open(os.path.join(sys.argv[1], name), "wb") as f:
            f.write(cart(kind))


if __name__ == "__main__":
    main()

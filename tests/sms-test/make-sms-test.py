#!/usr/bin/env python3
"""Builds the test cartridges of Sega's 8-bit consoles and the ColecoVision
this repository uses: one small Z80 program that keeps what it reads from
the controllers in its RAM, shows and sounds it.

Usage: make-sms-test.py <out dir>

Writes sms-test.sms (Master System), gg-test.gg (Game Gear), sg-test.sg
(SG-1000), cv-test.col (ColecoVision; it runs only with the
ColecoVision's BIOS, which starts it) and sms-phaser.sms (a Master System
program for the Light Phaser, below).

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

sms-phaser.sms shows a white screen (every colour white) and, each frame after
the frame flag: keeps the two ports' bytes (inverted: a Light Phaser's
trigger is $DC bit 4 in port 1, $DD bit 2 in port 2) at RAM +0 and +1,
counts frames at +4, waits for the first line of the picture and then reads
$DD as fast as it can until a gun sees light ($DD bit 6 for port 1's, bit 7
for port 2's, 0 when it does) or 768 reads have gone by (about 205 lines,
more than the picture's 192). The ports' TR and TH lines are set as inputs
($3F = $FF): the light comes in on TH. It keeps the line the light was seen on
(the V counter, $7E) at +6 ($FF when none), the $DD byte that saw it at +7,
the H counter ($7F, which the gun latches where it points) at +8, and how
many reads it took at +9 (low) and +10; each written when the frame's
search ends, so the RAM holds the last search that ended.

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


def program_phaser():
    ram = 0xC000
    vdp_data, vdp_ctl = 0xBE, 0xBF
    a = Asm(0)
    a.b(0xF3, 0xED, 0x56)  # DI; IM 1
    a.b(0x31, 0xF0, 0xDF)  # LD SP,$DFF0
    a.jp("start")
    a.org(0x0038)
    a.b(0xFB, 0xED, 0x4D)  # EI; RETI
    a.org(0x0066)
    a.b(0xED, 0x45)        # RETN: Pause does nothing here
    a.org(0x0100)
    a.label("start")
    a.b(0xAF)
    for i in range(16):
        a.b(0x32) ; a.b(*(ram + i).to_bytes(2, "little"))
    for r, v in {0: 0x04, 1: 0xC0, 2: 0xFF, 5: 0xFF, 6: 0xFB, 7: 0x00}.items():
        a.b(0x3E, v, 0xD3, vdp_ctl, 0x3E, 0x80 | r, 0xD3, vdp_ctl)
    # the ports' TR and TH lines as inputs (the guns' light comes in on TH)
    a.b(0x3E, 0xFF, 0xD3, 0x3F)       # OUT ($3F),$FF
    # every colour white: the background's tiles (all of colour 0) and the
    # backdrop (colour 16)
    a.b(0x3E, 0x00, 0xD3, vdp_ctl, 0x3E, 0xC0, 0xD3, vdp_ctl)
    a.b(0x06, 32, 0x3E, 0x3F)          # LD B,32; LD A,$3F
    a.label("cram")
    a.b(0xD3, vdp_data)                # OUT (data),A
    a.jr(0x10, "cram")                 # DJNZ
    a.label("main")
    a.label("wait")
    a.b(0xDB, vdp_ctl, 0xE6, 0x80)   # the frame flag
    a.jr(0x28, "wait")
    a.b(0xDB, 0xDC, 0x2F, 0x32) ; a.b(*(ram + 0).to_bytes(2, "little"))
    a.b(0xDB, 0xDD, 0x2F, 0x32) ; a.b(*(ram + 1).to_bytes(2, "little"))
    a.b(0x21) ; a.b(*(ram + 4).to_bytes(2, "little")) ; a.b(0x34)   # INC (ram+4)
    # the first line of the picture: the V counter back at 0
    a.label("top")
    a.b(0xDB, 0x7E, 0xB7)            # IN A,($7E); OR A
    a.jr(0x20, "top")                # JR NZ
    a.b(0x11, 0x00, 0x00)            # LD DE,0: reads
    a.label("poll")
    a.b(0xDB, 0xDD)                  # IN A,($DD)
    a.b(0xE6, 0xC0, 0xFE, 0xC0)      # AND $C0; CP $C0
    a.jr(0x20, "seen")               # JR NZ: a gun sees light
    a.b(0x13)                        # INC DE
    a.b(0x7A, 0xFE, 0x03)            # LD A,D; CP 3: 768 reads, about 205 lines
    a.jr(0x20, "poll")
    a.b(0x3E, 0xFF, 0x32) ; a.b(*(ram + 6).to_bytes(2, "little"))   # no light this frame
    a.jp("done")
    a.label("seen")
    a.b(0x47)                        # LD B,A
    a.b(0xDB, 0x7F, 0x4F)            # IN A,($7F); LD C,A: the H counter
    a.b(0xDB, 0x7E)                  # IN A,($7E): the line
    a.b(0x32) ; a.b(*(ram + 6).to_bytes(2, "little"))
    a.b(0x78, 0x32) ; a.b(*(ram + 7).to_bytes(2, "little"))
    a.b(0x79, 0x32) ; a.b(*(ram + 8).to_bytes(2, "little"))
    a.b(0x7B, 0x32) ; a.b(*(ram + 9).to_bytes(2, "little"))
    a.b(0x7A, 0x32) ; a.b(*(ram + 10).to_bytes(2, "little"))
    a.label("done")
    a.jp("main")
    return a.resolve()


def cart(kind):
    code = program_phaser() if kind == "phaser" else program(kind)
    size = 0x8000
    rom = bytearray(size)
    rom[0:len(code)] = code
    if kind in ("sms", "gg", "phaser"):
        # the header a BIOS checks: "TMR SEGA", the checksum of the first 32
        # KiB less the header, the region (4: export Master System, 7:
        # international Game Gear) and the size code (C: 32 KiB)
        rom[0x7FF0:0x7FF8] = b"TMR SEGA"
        total = sum(rom[0:0x7FF0]) & 0xFFFF
        rom[0x7FFA:0x7FFC] = total.to_bytes(2, "little")
        rom[0x7FFF] = (0x7C if kind == "gg" else 0x4C)
    return bytes(rom)


NAMES = {"sms": "sms-test.sms", "gg": "gg-test.gg", "sg": "sg-test.sg", "cv": "cv-test.col", "phaser": "sms-phaser.sms"}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for kind, name in NAMES.items():
        with open(os.path.join(sys.argv[1], name), "wb") as f:
            f.write(cart(kind))


if __name__ == "__main__":
    main()

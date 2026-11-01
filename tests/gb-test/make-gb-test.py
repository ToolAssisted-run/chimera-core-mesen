#!/usr/bin/env python3
"""Builds the Game Boy test cartridge this repository uses: a small SM83
program that keeps what it reads from the buttons in its RAM, and shows and
sounds them.

Usage: make-gb-test.py <out dir>

Writes gb-test.gb (32 KiB, MBC1 with 8 KiB of battery-backed RAM). Its
header says it runs on the Game Boy and, in colour, on the Game Boy Color,
so the same file is the test of both machines. It also writes gb-rtc.gb,
the same program on an MBC3 cartridge with a clock, which each frame also
reads the clock, and gb-tilt.gb, the same program on an MBC7 cartridge
(the one with a tilt sensor), which each frame reads the sensor (below).

What the program does:
  - at power on it keeps the A register the boot program left in RAM $C002:
    $01 on a Game Boy, $11 on a Game Boy Color, which is how a game tells
    them apart; then, in the vertical blank, it turns the screen off, clears the
    picture memory (tile 0 is all colour 0, and every tile of the map is
    tile 0), turns the screen and the background back on, and switches the
    sound on with channel 1 (a square wave) at full volume;
  - each frame, in the vertical blank, it reads the buttons (the direction
    pad, then A, B, Select and Start) into RAM $C000 as one byte, Down Up
    Left Right Start Select B A from the highest bit, 1 for held, and counts
    frames in $C001; it writes both into its battery RAM ($A000-$A001);
  - the picture is colour 0 everywhere, and colour 0 is the buttons' byte:
    the Game Boy's palette ($FF47) is the byte, and the Game Boy Color's
    background colour 0 is the byte twice ($FF68/$FF69);
  - channel 1 plays at the frequency the byte gives (low 8 bits the byte,
    high bits 6), restarted each frame.

gb-rtc.gb (MBC3, a clock, 8 KiB of battery-backed RAM) also latches the
clock each frame (writes 0 then 1 to $6000), reads its five registers
(seconds, minutes, hours, the day counter's low 8 bits, and its top bit
with the halt and carry flags; RAM banks $08-$0C at $A000) into RAM
$C010-$C014, and selects RAM bank 0 again.

gb-tilt.gb (MBC7, 32 KiB) turns the sensor's registers on at power on
($0A to $0000, $40 to $4000), keeps nothing in battery RAM (the MBC7 has
an EEPROM, not RAM, there), and each frame resets the sensor's latch ($55
to $A000), latches it ($AA to $A010) and reads its four bytes (X low and
high at $A020 and $A030, Y low and high at $A040 and $A050) into RAM
$C010-$C013.

The 48 bytes at $0104-$0133 (the logo) are left zero: the boot program Mesen has of
its own (SameBoy's) runs the game without Nintendo's logo, and this
repository holds nothing of Nintendo's. With Nintendo's own boot program
(the Boot ROM setting) the cartridge would not start.

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

    def jr(self, op, name):
        self.b(op, 0)
        self.fix.append((len(self.out) - 1, name))

    def resolve(self):
        for at, name in self.fix:
            rel = self.labels[name] - (self.origin + at + 1)
            assert -128 <= rel < 128, name
            self.out[at] = rel & 0xFF
        return self.out


def program(rtc=False, tilt=False):
    a = Asm(0x150)
    a.b(0xF3)                          # DI
    a.b(0xEA, 0x02, 0xC0)              # LD ($C002),A: the boot program's A, $01 or $11
    a.b(0x31, 0xFE, 0xFF)              # LD SP,$FFFE
    a.b(0x3E, 0x0A, 0xEA, 0x00, 0x00)  # LD A,$0A; LD ($0000),A: the cartridge RAM on
    if tilt:
        a.b(0x3E, 0x40, 0xEA, 0x00, 0x40)  # LD A,$40; LD ($4000),A: the MBC7's registers on
    a.label("wait0")
    a.b(0xF0, 0x44, 0xFE, 0x90)        # LDH A,(LY); CP 144
    a.jr(0x20, "wait0")                # JR NZ
    a.b(0xAF, 0xE0, 0x40)              # XOR A; LDH (LCDC),A: the screen off
    a.b(0x21, 0x00, 0x80)              # LD HL,$8000
    a.b(0x01, 0x00, 0x20)              # LD BC,$2000
    a.label("clear")
    a.b(0xAF, 0x22)                    # XOR A; LD (HL+),A
    a.b(0x0B, 0x78, 0xB1)              # DEC BC; LD A,B; OR C
    a.jr(0x20, "clear")
    a.b(0x3E, 0x91, 0xE0, 0x40)        # LCDC = $91: on, background on, tiles at $8000
    a.b(0x3E, 0x80, 0xE0, 0x26)        # NR52: sound on
    a.b(0x3E, 0x77, 0xE0, 0x24)        # NR50: full volume both sides
    a.b(0x3E, 0xFF, 0xE0, 0x25)        # NR51: every channel both sides
    a.b(0x3E, 0x80, 0xE0, 0x11)        # NR11: duty 50%
    a.b(0x3E, 0xF0, 0xE0, 0x12)        # NR12: volume 15, no envelope
    a.label("main")
    a.label("wait")
    a.b(0xF0, 0x44, 0xFE, 0x90)        # wait for line 144
    a.jr(0x20, "wait")
    a.b(0x3E, 0x20, 0xE0, 0x00)        # select the direction pad
    a.b(0xF0, 0x00, 0xF0, 0x00)        # read it twice (it settles)
    a.b(0xE6, 0x0F, 0xCB, 0x37, 0x47)  # AND $0F; SWAP A; LD B,A
    a.b(0x3E, 0x10, 0xE0, 0x00)        # select the buttons
    a.b(0xF0, 0x00, 0xF0, 0x00)
    a.b(0xE6, 0x0F, 0xB0, 0x2F, 0x47)  # AND $0F; OR B; CPL; LD B,A: 1 = held
    a.b(0x3E, 0x30, 0xE0, 0x00)        # select nothing
    a.b(0x78, 0xEA, 0x00, 0xC0)        # LD A,B; LD ($C000),A
    a.b(0x21, 0x01, 0xC0, 0x34)        # LD HL,$C001; INC (HL)
    if rtc:
        a.b(0xAF, 0xEA, 0x00, 0x60)    # XOR A; LD ($6000),A
        a.b(0x3E, 0x01, 0xEA, 0x00, 0x60)  # LD A,1; LD ($6000),A: the clock latched
        for i in range(5):
            a.b(0x3E, 0x08 + i, 0xEA, 0x00, 0x40)  # LD A,$08+i; LD ($4000),A: register i
            a.b(0xFA, 0x00, 0xA0, 0xEA, 0x10 + i, 0xC0)  # LD A,($A000); LD ($C010+i),A
        a.b(0xAF, 0xEA, 0x00, 0x40)    # XOR A; LD ($4000),A: RAM bank 0 again
    if tilt:
        a.b(0x3E, 0x55, 0xEA, 0x00, 0xA0)  # LD A,$55; LD ($A000),A: the latch reset
        a.b(0x3E, 0xAA, 0xEA, 0x10, 0xA0)  # LD A,$AA; LD ($A010),A: latched
        for i in range(4):
            a.b(0xFA, 0x20 + 0x10 * i, 0xA0, 0xEA, 0x10 + i, 0xC0)  # LD A,($A0x0); LD ($C01x),A
    else:
        a.b(0x78, 0xEA, 0x00, 0xA0)        # battery RAM: the byte...
        a.b(0xFA, 0x01, 0xC0, 0xEA, 0x01, 0xA0)  # ...and the frame count
    a.b(0x78, 0xE0, 0x47)              # BGP = the byte
    a.b(0x3E, 0x80, 0xE0, 0x68)        # BCPS: colour 0 of palette 0, counting up
    a.b(0x78, 0xE0, 0x69, 0xE6, 0x7F, 0xE0, 0x69)  # BCPD = the byte, the byte & $7F
    a.b(0x78, 0xE0, 0x13)              # NR13 = the byte
    a.b(0x3E, 0x86, 0xE0, 0x14)        # NR14: restart, frequency high bits 6
    a.label("leave")
    a.b(0xF0, 0x44, 0xFE, 0x90)        # wait for the line to change
    a.jr(0x28, "leave")
    if rtc or tilt:
        a.b(0xC3, a.labels["main"] & 0xFF, a.labels["main"] >> 8)  # JP main: too far for JR
    else:
        a.jr(0x18, "main")
    return a.resolve()


def cart(rtc=False, tilt=False):
    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])  # NOP; JP $0150
    rom[0x134:0x143] = b"CHIMERA MESEN".ljust(15, b"\0")
    rom[0x143] = 0x80   # runs on the Game Boy and, in colour, on the Game Boy Color
    rom[0x146] = 0x00
    # MBC3, clock, RAM, battery; MBC7, its sensor and EEPROM; or MBC1, RAM, battery
    rom[0x147] = 0x10 if rtc else 0x22 if tilt else 0x03
    rom[0x148] = 0x00   # 32 KiB
    rom[0x149] = 0x02   # 8 KiB of RAM
    rom[0x14A] = 0x01
    rom[0x14B] = 0x00
    code = program(rtc, tilt)
    rom[0x150:0x150 + len(code)] = code
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - rom[i] - 1) & 0xFF
    rom[0x14D] = x
    total = sum(rom) - rom[0x14E] - rom[0x14F]
    rom[0x14E:0x150] = (total & 0xFFFF).to_bytes(2, "big")
    return bytes(rom)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(os.path.join(sys.argv[1], "gb-test.gb"), "wb") as f:
        f.write(cart())
    with open(os.path.join(sys.argv[1], "gb-rtc.gb"), "wb") as f:
        f.write(cart(rtc=True))
    with open(os.path.join(sys.argv[1], "gb-tilt.gb"), "wb") as f:
        f.write(cart(tilt=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Builds the Super NES test cartridges this repository uses: a small 65816
program that keeps what it reads from the controller ports in its RAM.

Usage: make-snes-test.py <out dir>

Writes snes-test.sfc (LoROM, 32 KiB, 2 KiB of battery-backed RAM),
snes-devices.sfc (the same program reading a mouse and the Super Scope,
below) and one
cartridge per chip that runs a program of its own, each only a header and
the same test program: snes-dsp1.sfc, snes-dsp1b.sfc, snes-dsp2.sfc,
snes-dsp3.sfc, snes-dsp4.sfc, snes-st010.sfc, snes-st011.sfc and
snes-st018.sfc. Mesen tells the chips apart by the header's ROM type and
title, as it does for the games that have them. snes-rtc.sfc is the same
program on a cartridge with an SPC7110 and its clock (the RTC-4513); each
frame it also reads the clock (below). That one is 64 KiB with its header
where a HiROM cartridge has it ($FFC0 of the file): Mesen maps an SPC7110
cartridge's program the HiROM way ($00:8000 is the file's $8000), and its
mapping does not wrap round a 32 KiB file. The first 32 KiB are zeros.

What the program does:
  - at power on it clears its RAM, turns every layer off (so the picture
    is the backdrop colour only), sets the controller port's I/O line high
    (for the multitap) and turns on the vertical blank interrupt and the
    automatic read of the pads;
  - on snes-dsp1.sfc and snes-dsp1b.sfc it first asks the DSP-1 to multiply
    0x4000 by 0x4000 (its command 0x00) and keeps the answer in RAM $30-$31:
    0x2000 when the chip runs its real program;
  - each vertical blank it waits for the automatic read to start and to
    end, counts frames in RAM $00, copies the eight bytes
    of the automatic read ($4218-$421F: pads 1 to 4 on the two data lines)
    to RAM $10-$17, then reads port 2 by hand sixteen times with the I/O
    line low and keeps each read in RAM $20-$2F (a multitap's pads 4 and 5
    on bits 0 and 1), and makes the backdrop the colour of pad 1's bits;
  - it writes the frame count and pad 1's two bytes into its battery RAM
    ($70:0000-$70:0002), so a saved game holds them.

snes-devices.sfc reads the ports for the mouse and the Super Scope
instead of the multitap: after the automatic read (the first 16 bits of each
port, at $10-$17 as above) it reads 16 more bits by hand from each port,
with the I/O line left high and no new strobe: RAM $40-$4F from port 1
($4016 bit 0), $50-$5F from port 2 ($4017 bit 0); a mouse's third and
fourth bytes (its vertical and horizontal movement). Then it keeps the
picture chip's latched beam position, which the Super Scope sets where it
points: $213F (bit 6: latched) at $60, $213C twice (horizontal, low then
high) at $61-$62, $213D twice (vertical) at $63-$64.

snes-rtc.sfc also reads the SPC7110's clock each frame, after the pads: it
turns the clock on ($4840 = 1), asks to read from register 0 ($4841 = $0C,
then 0), reads the sixteen registers ($4841 sixteen times: seconds,
minutes, hours, day, month and year, a digit each, low digit first, then
the day of the week and three control registers) into RAM $70-$7F, and
turns the clock off again ($4840 = 0).

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
        """a branch to a label (8-bit relative)"""
        self.b(op, 0)
        self.fix.append((len(self.out) - 1, name))

    def resolve(self):
        for at, name in self.fix:
            rel = self.labels[name] - (self.origin + at + 1)
            assert -128 <= rel < 128, name
            self.out[at] = rel & 0xFF
        return self.out


def lo(v):
    return v & 0xFF


def hi(v):
    return (v >> 8) & 0xFF


def program(dsp_test, devices=False, rtc=False):
    a = Asm(0x8000)
    a.label("reset")
    a.b(0x78)                      # SEI
    a.b(0x18, 0xFB)                # CLC; XCE: native mode
    a.b(0xC2, 0x30)                # REP #$30
    a.b(0xA2, 0xFF, 0x1F)          # LDX #$1FFF
    a.b(0x9A)                      # TXS
    a.b(0xA9, 0x00, 0x00)          # LDA #$0000
    a.b(0x5B)                      # TCD: direct page 0
    a.b(0xE2, 0x30)                # SEP #$30
    a.b(0xA9, 0x80, 0x8D, 0x00, 0x21)  # force blank
    a.b(0x9C, 0x00, 0x42)          # STZ $4200
    a.b(0xA2, 0x00)                # LDX #0
    a.label("clear")
    a.b(0x74, 0x00)                # STZ $00,X
    a.b(0xE8)                      # INX
    a.br(0xD0, "clear")            # BNE
    for reg in (0x212C, 0x212D, 0x2130, 0x2131):
        a.b(0x9C, lo(reg), hi(reg))  # no layer on either screen, no colour maths
    a.b(0xA9, 0x80, 0x8D, 0x01, 0x42)  # $4201 = $80: the I/O line high
    if dsp_test:
        # the DSP-1's multiply: command 0x00, then K and I, 16 bits each,
        # low byte first; then the answer's two bytes. Each byte waits for
        # the chip's RQM (bit 7 of its status at $30:C000).
        def wait():
            name = "rqm%d" % len(a.out)
            a.label(name)
            a.b(0xAF, 0x00, 0xC0, 0x30)  # LDA $30C000
            a.br(0x10, name)              # BPL: not ready
        for v in (0x00, 0x00, 0x40, 0x00, 0x40):
            wait()
            a.b(0xA9, v, 0x8F, 0x00, 0x80, 0x30)  # STA $308000
        for dst in (0x30, 0x31):
            wait()
            a.b(0xAF, 0x00, 0x80, 0x30, 0x85, dst)  # LDA $308000; STA dst
    a.b(0xA9, 0x0F, 0x8D, 0x00, 0x21)  # display on, full brightness
    a.b(0xA9, 0x81, 0x8D, 0x00, 0x42)  # NMI and the automatic pad read
    a.label("main")
    a.b(0xCB)                      # WAI
    a.br(0x80, "main")             # BRA
    a.label("nmi")
    a.b(0xE2, 0x30)                # SEP #$30
    a.b(0xAD, 0x10, 0x42)          # LDA $4210: acknowledge
    # the automatic read starts a little after the interrupt and takes
    # three lines; its registers are not the pads' while it runs. Wait for
    # it to start (at most 256 tries, far more than it takes), then to end.
    a.b(0xA2, 0x00)                # LDX #0
    a.label("start")
    a.b(0xAD, 0x12, 0x42, 0x29, 0x01)  # LDA $4212; AND #1
    a.br(0xD0, "busy")             # started
    a.b(0xCA)                      # DEX
    a.br(0xD0, "start")
    a.label("busy")
    a.b(0xAD, 0x12, 0x42, 0x29, 0x01)  # LDA $4212; AND #1: the read still going
    a.br(0xD0, "busy")
    a.b(0xA2, 0x00)
    a.label("copy")
    a.b(0xBD, 0x18, 0x42, 0x95, 0x10)  # LDA $4218,X; STA $10,X
    a.b(0xE8, 0xE0, 0x08)          # INX; CPX #8
    a.br(0xD0, "copy")
    if devices:
        # 16 more bits from each port, after the automatic read's 16
        a.b(0xA2, 0x00)
        a.label("more")
        a.b(0xAD, 0x16, 0x40, 0x95, 0x40)  # LDA $4016; STA $40,X
        a.b(0xAD, 0x17, 0x40, 0x95, 0x50)  # LDA $4017; STA $50,X
        a.b(0xE8, 0xE0, 0x10)          # INX; CPX #16
        a.br(0xD0, "more")
        # the latched beam position
        a.b(0xAD, 0x3F, 0x21, 0x85, 0x60)  # LDA $213F; STA $60
        a.b(0xAD, 0x3C, 0x21, 0x85, 0x61)  # LDA $213C; STA $61
        a.b(0xAD, 0x3C, 0x21, 0x85, 0x62)
        a.b(0xAD, 0x3D, 0x21, 0x85, 0x63)  # LDA $213D; STA $63
        a.b(0xAD, 0x3D, 0x21, 0x85, 0x64)
    else:
        a.b(0x9C, 0x01, 0x42)          # STZ $4201: the I/O line low
        a.b(0xA9, 0x01, 0x8D, 0x16, 0x40, 0x9C, 0x16, 0x40)  # strobe
        a.b(0xA2, 0x00)
        a.label("manual")
        a.b(0xAD, 0x17, 0x40, 0x95, 0x20)  # LDA $4017; STA $20,X
        a.b(0xE8, 0xE0, 0x10)          # INX; CPX #16
        a.br(0xD0, "manual")
        a.b(0xA9, 0x80, 0x8D, 0x01, 0x42)  # the I/O line high again
    if rtc:
        a.b(0xA9, 0x01, 0x8D, 0x40, 0x48)  # $4840 = 1: the clock on
        a.b(0xA9, 0x0C, 0x8D, 0x41, 0x48)  # $4841 = $0C: read
        a.b(0x9C, 0x41, 0x48)              # $4841 = 0: from register 0
        a.b(0xA2, 0x00)
        a.label("rtc")
        a.b(0xAD, 0x41, 0x48, 0x95, 0x70)  # LDA $4841; STA $70,X
        a.b(0xE8, 0xE0, 0x10)              # INX; CPX #16
        a.br(0xD0, "rtc")
        a.b(0x9C, 0x40, 0x48)              # $4840 = 0: the clock off
    a.b(0xE6, 0x00)                # INC $00
    a.b(0x9C, 0x21, 0x21)          # CGRAM address 0: the backdrop
    a.b(0xA5, 0x11, 0x8D, 0x22, 0x21)  # pad 1's B Y Select Start Up Down Left Right
    a.b(0xA5, 0x10, 0x4A, 0x8D, 0x22, 0x21)  # its A X L R, shifted into 15 bits
    a.b(0xA5, 0x00, 0x8F, 0x00, 0x00, 0x70)  # battery RAM: the frame count...
    a.b(0xA5, 0x10, 0x8F, 0x01, 0x00, 0x70)  # ...and pad 1
    a.b(0xA5, 0x11, 0x8F, 0x02, 0x00, 0x70)
    a.b(0x40)                      # RTI
    a.label("rti")
    a.b(0x40)
    return a.resolve(), a.labels


# name -> (title, ROM type, cartridge type at $7FBF)
CARTS = {
    "snes-test": ("CHIMERA MESEN TEST", 0x02, 0x00),
    "snes-devices": ("CHIMERA DEVICES TEST", 0x02, 0x00),
    "snes-dsp1": ("PILOTWINGS", 0x03, 0x00),
    "snes-dsp1b": ("CHIMERA DSP1B TEST", 0x03, 0x00),
    "snes-dsp2": ("DUNGEON MASTER", 0x03, 0x00),
    "snes-dsp3": (b"SD\xB6\xDE\xDD\xC0\xDE\xD1GX", 0x03, 0x00),
    "snes-dsp4": ("TOP GEAR 3000", 0x03, 0x00),
    "snes-st010": ("CHIMERA ST010 TEST", 0xF5, 0x01),
    "snes-st011": ("2DAN MORITA SHOUGI", 0xF5, 0x01),
    "snes-st018": ("CHIMERA ST018 TEST", 0xF5, 0x02),
    "snes-rtc": ("CHIMERA RTC TEST", 0xF9, 0x00),
}


def cart(name):
    title, rom_type, cart_type = CARTS[name]
    code, labels = program(name in ("snes-dsp1", "snes-dsp1b"), name == "snes-devices", name == "snes-rtc")
    rom = bytearray(0x8000)
    rom[0:len(code)] = code
    if isinstance(title, str):
        title = title.encode("ascii")
    rom[0x7FC0:0x7FD5] = title.ljust(21, b" ")
    rom[0x7FDA] = 0x33       # the extended header is there
    rom[0x7FBF] = cart_type
    rom[0x7FD5] = 0x20       # LoROM
    rom[0x7FD6] = rom_type
    rom[0x7FD7] = 0x05       # 32 KiB
    rom[0x7FD8] = 0x01       # 2 KiB of RAM
    rom[0x7FD9] = 0x01       # North America
    for vec in (0x7FE4, 0x7FE6, 0x7FE8, 0x7FEE, 0x7FF4, 0x7FF8, 0x7FFE):
        rom[vec:vec + 2] = labels["rti"].to_bytes(2, "little")
    rom[0x7FEA:0x7FEC] = labels["nmi"].to_bytes(2, "little")
    rom[0x7FFA:0x7FFC] = labels["nmi"].to_bytes(2, "little")
    rom[0x7FFC:0x7FFE] = labels["reset"].to_bytes(2, "little")
    rom[0x7FDC:0x7FE0] = b"\xFF\xFF\x00\x00"
    if name == "snes-rtc":
        rom[0x7FD5] = 0x3A   # HiROM, fast, SPC7110
        rom[0x7FD7] = 0x06   # 64 KiB
        rom = bytearray(0x8000) + rom
        base = 0xFFC0 - 0x7FC0
    else:
        base = 0
    total = sum(rom) & 0xFFFF
    rom[base + 0x7FDC:base + 0x7FDE] = (total ^ 0xFFFF).to_bytes(2, "little")
    rom[base + 0x7FDE:base + 0x7FE0] = total.to_bytes(2, "little")
    return bytes(rom)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for name in CARTS:
        with open(os.path.join(sys.argv[1], name + ".sfc"), "wb") as f:
            f.write(cart(name))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The tilt sensors of Game Boy and Game Boy Advance cartridges in the test
programs (gb-tilt.gb, an MBC7 cartridge; gba-tilt.gba, the game code Mesen
gives a tilt sensor): the schedule, and what the sensor must give. Used by
waterbox/tests/systems.sh (<machine>:tilt).

    tilt.py schedule <frames> <out.inputs> <x> <y> [<console>,<pad>]
        an input file setting the tilt (axes 0 and 1) to x and y on every
        frame, nothing pressed (the machine's wire: --wire's numbers)
    tilt.py expect <gb|gba> <x> <y>
        the four bytes (hex) the program keeps: X low and high, Y low and
        high, as Mesen's sensor gives them for that tilt
        (GbMbc7Accelerometer: X = 0x81D0 - x/500, Y = 0x81D0 + y/500;
        GbaTiltSensor: X = 0x392 - x/143, Y = 0x3A0 + y/143, its high bytes
        on 4 bits, X's with bit 7 set), C's division, toward zero
    tilt.py read <gb|gba> <RAM dump>
        the four bytes (hex) from the program's RAM (WRAM $C010, EWRAM +0x20)
"""
import sys


def cdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def expect(m, x, y):
    if m == "gb":
        ax = (-cdiv(x, 500) + 0x81D0) & 0xFFFF
        ay = (cdiv(y, 500) + 0x81D0) & 0xFFFF
        out = [ax & 0xFF, ax >> 8, ay & 0xFF, ay >> 8]
    else:
        ax = (-cdiv(x, 143) + 0x392) & 0xFFFF
        ay = (cdiv(y, 143) + 0x3A0) & 0xFFFF
        out = [ax & 0xFF, 0x80 | ((ax >> 8) & 0x0F), ay & 0xFF, (ay >> 8) & 0x0F]
    return "".join("%02x" % b for b in out)


def read(m, path):
    ram = open(path, "rb").read()
    at = 0x10 if m == "gb" else 0x20
    return "".join("%02x" % b for b in ram[at:at + 4])


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "schedule":
        frames, out, x, y = int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
        console, pad = (int(v) for v in sys.argv[6].split(","))
        line = "|" + "." * console + "|" + "." * pad + "|@a0=%d a1=%d|" % (x, y)
        open(out, "w").write((line + "\n") * frames)
    elif cmd == "expect":
        print(expect(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])))
    elif cmd == "read":
        print(read(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

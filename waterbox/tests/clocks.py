#!/usr/bin/env python3
"""The cartridges' clocks in the test programs: what each program keeps of
its cartridge's clock, and what the clock must say. Used by
waterbox/tests/systems.sh (the <machine>:clock-start checks).

    clocks.py expect <machine> <clock start> <frames>
        the bytes (hex) the program keeps after <frames> frames of a project
        whose Clock Start is <clock start> (seconds since 1970-01-01 UTC)
    clocks.py read <machine> <RAM dump>
        the bytes (hex) the program keeps, from its RAM
    clocks.py say <machine> <hex>
        the bytes as a date and time a person reads

The machines and what their programs keep:
    gba   the S-3511A (tests/gba-test): EWRAM +0x10, seven BCD bytes: year,
          month, day, day of the week, hour (12-hour, bit 7 = PM), minute,
          second
    ws    the same chip on a Bandai 2003 cartridge (tests/ws-test, ws-rtc.ws):
          Work RAM $0110, the same seven bytes
    gb    the MBC3's clock (tests/gb-test, gb-rtc.gb): WRAM $C010, five
          bytes: seconds, minutes, hours, the day counter's low 8 bits, its
          top bit with the halt and carry flags
    snes  the SPC7110's RTC-4513 (tests/snes-test, snes-rtc.sfc): WRAM $70,
          thirteen registers of a digit each: second, minute, hour, day,
          month and year, the low digit first, then the day of the week
          (0 Sunday)

How far each clock has gone after <frames> frames, when the last frame's
reading is taken: the S-3511A and the RTC-4513 read the machine's time
(patch 0009), the start plus the frames before the last (the core moves it
after each frame) at the machine's frame rate; the MBC3's clock counts the
Game Boy's own cycles from power on (70224 a frame, 4194304 a second).
"""
import datetime
import sys

# where the program keeps the clock: the domain's offset and how many bytes
WHERE = {"gba": (0x10, 7), "ws": (0x110, 7), "gb": (0x10, 5), "snes": (0x70, 13)}
# the frame rate as a fraction, as the core gives it (vsync)
RATE = {"gba": (4194304, 70224), "ws": (12000, 159), "snes": (236250000, 3931026)}
EPOCH2000 = 946684800


def bcd(v):
    return (v // 10) << 4 | v % 10


def expect(machine, start, frames):
    if machine == "gb":
        seconds = start + frames * 70224 // 4194304
    else:
        num, den = RATE[machine]
        ms = start * 1000 + (frames - 1) * 1000 * den // num
        seconds = ms // 1000
    t = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=seconds)
    if machine in ("gba", "ws"):
        days2000 = (seconds - EPOCH2000) // 86400
        hour = t.hour if t.hour < 12 else t.hour - 12
        out = [bcd(t.year % 100), bcd(t.month), bcd(t.day), days2000 % 7,
               bcd(hour) | (0x80 if t.hour >= 12 else 0), bcd(t.minute), bcd(t.second)]
    elif machine == "gb":
        # the time of day the clock started at, and the seconds since; the
        # day counter starts at 0 and does not pass a day in these runs
        days = (seconds // 86400) - (start // 86400)
        out = [t.second, t.minute, t.hour, days & 0xFF, (days >> 8) & 1]
    else:
        year = t.year % 100
        weekday = (seconds // 86400 + 4) % 7
        out = []
        for v in (t.second, t.minute, t.hour, t.day, t.month, year):
            out += [v % 10, v // 10]
        out.append(weekday)
    return "".join("%02x" % b for b in out)


def read(machine, path):
    off, n = WHERE[machine]
    ram = open(path, "rb").read()
    return "".join("%02x" % b for b in ram[off:off + n])


def say(machine, text):
    b = bytes.fromhex(text)
    if machine in ("gba", "ws"):
        h = "%x" % (b[4] & 0x3F)
        return "%02x-%02x-%02x %s%s:%02x:%02x, day of the week %d" % (
            b[0], b[1], b[2], h, " PM" if b[4] & 0x80 else " AM", b[5], b[6], b[3])
    if machine == "gb":
        return "%02d:%02d:%02d, day %d" % (b[2], b[1], b[0], b[3] | (b[4] & 1) << 8)
    d = [b[i] + 10 * b[i + 1] for i in range(0, 12, 2)]
    return "%02d-%02d-%02d %02d:%02d:%02d, day of the week %d" % (d[5], d[4], d[3], d[2], d[1], d[0], b[12])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "expect":
        print(expect(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])))
    elif cmd == "read":
        print(read(sys.argv[2], sys.argv[3]))
    elif cmd == "say":
        print(say(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

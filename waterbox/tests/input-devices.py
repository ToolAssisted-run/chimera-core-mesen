#!/usr/bin/env python3
"""The input devices' test schedules, and what the input test cartridge
(tests/input-test) shows of them in its RAM. Used by run-gate.sh.

    input-devices.py schedule <device> <out.inputs>
        the run-native/run-wbx input file for <device>: fourScore, zapper,
        arkanoid (240 frames, every control moving)
    input-devices.py movie <device> <in.inputs> <out.txt>
        the same schedule as a Chimera movie for a project whose ports hold
        <device>: an entry's groups are the console's, then each player's,
        a group's axes first (5 wide and a comma), then its buttons' letters,
        and only the controls the machine has (the core's IsButtonActive and
        IsAxisActive)
    input-devices.py check <device> <in.inputs> <RAM dump>
        whether the RAM shows the schedule's last frame: the four pads and
        the Four Score's signatures; the Zapper's trigger; the Arkanoid
        controller's knob and button. Prints what it read; exit 1 if wrong.
    input-devices.py light <RAM dump>
        the cartridge's light reading: "<seen 0/1> <reads>"
"""
import sys

PAD_FIELD = "UDLRSsBA"   # the input file's order
WIRE = "ABsSUDLR"        # the package's order (and the cartridge's bits)
NEUTRAL = {"x": 32768, "y": 32768, "p": 80}


def schedule(device):
    lines = []
    for f in range(240):
        pads = []
        for p in range(4 if device == "fourScore" else 1):
            held = WIRE[(f // 8 + 2 * p) % 8]
            pads.append("".join(c if c == held else "." for c in PAD_FIELD))
        extra = ""
        if device == "zapper":
            extra = "@%sx=%d y=%d" % ("T " if (f // 5) % 2 else "", (f * 997) % 65536, (f * 2191) % 65536)
        elif device == "arkanoid":
            extra = "@%sp=%d" % ("F " if (f // 3) % 2 else "", (f * 7) % 161)
        lines.append("|..|" + "|".join(pads) + "|" + (extra + "|" if extra else ""))
    return lines


def parse(line):
    """an input line -> (console, [pads as sets of letters], {T, F}, axes)"""
    fields = line.strip().strip("|").split("|")
    console = fields[0]
    pads, extra = [], ""
    for f in fields[1:]:
        if f.startswith("@"):
            extra = f[1:]
        else:
            pads.append({c for c in f if c != "."})
    held, axes = set(), dict(NEUTRAL)
    for tok in extra.split():
        if tok in ("T", "F"):
            held.add(tok)
        else:
            k, v = tok.split("=")
            axes[k] = int(v)
    return console, pads, held, axes


def movie(device, lines):
    out = []
    for line in lines:
        console, pads, held, axes = parse(line)
        def pad(i):
            s = pads[i] if i < len(pads) else set()
            return "".join(c if c in s else "." for c in WIRE)
        groups = [console, pad(0)]
        if device == "fourScore":
            groups += [pad(1), pad(2), pad(3)]
        elif device == "zapper":
            groups.append("%5d,%5d,%s" % (axes["x"], axes["y"], "T" if "T" in held else "."))
        elif device == "arkanoid":
            groups.append("%5d,%s" % (axes["p"], "F" if "F" in held else "."))
        out.append("|" + "|".join(groups) + "|")
    return out


def bits(ram, base, n, bit=0):
    return [(ram[base + i] >> bit) & 1 for i in range(n)]


def check(device, lines, ram):
    console, pads, held, axes = parse(lines[-1])
    want = lambda i: [1 if c in pads[i] else 0 for c in WIRE]
    problems = []
    if device == "fourScore":
        got = {"P1": bits(ram, 0x10, 8), "P3": bits(ram, 0x18, 8), "sig4016": bits(ram, 0x20, 8),
               "P2": bits(ram, 0x30, 8), "P4": bits(ram, 0x38, 8), "sig4017": bits(ram, 0x40, 8)}
        exp = {"P1": want(0), "P3": want(2), "sig4016": [0, 0, 0, 1, 0, 0, 0, 0],
               "P2": want(1), "P4": want(3), "sig4017": [0, 0, 1, 0, 0, 0, 0, 0]}
        for k in exp:
            if got[k] != exp[k]:
                problems.append("%s read %s, not %s" % (k, got[k], exp[k]))
        print("four pads and both signatures as the last frame holds them" if not problems else "; ".join(problems))
    elif device == "zapper":
        trig = (ram[0x30] >> 4) & 1
        if trig != (1 if "T" in held else 0):
            problems.append("trigger read %d" % trig)
        print("trigger %d as the last frame holds it" % trig if not problems else "; ".join(problems))
    elif device == "arkanoid":
        knob = 0
        for b in bits(ram, 0x30, 8, 4):
            knob = (knob << 1) | (1 - b)
        fire = (ram[0x30] >> 3) & 1
        if knob != 0x54 + axes["p"]:
            problems.append("knob read 0x%02x, not 0x%02x" % (knob, 0x54 + axes["p"]))
        if fire != (1 if "F" in held else 0):
            problems.append("button read %d" % fire)
        print("knob 0x%02x and button %d as the last frame holds them" % (knob, fire) if not problems else "; ".join(problems))
    return not problems


def main():
    cmd = sys.argv[1]
    if cmd == "schedule":
        open(sys.argv[3], "w").write("\n".join(schedule(sys.argv[2])) + "\n")
    elif cmd == "movie":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        open(sys.argv[4], "w").write("\n".join(movie(sys.argv[2], lines)) + "\n")
    elif cmd == "check":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        sys.exit(0 if check(sys.argv[2], lines, open(sys.argv[4], "rb").read()) else 1)
    elif cmd == "light":
        ram = open(sys.argv[2], "rb").read()
        print(ram[0x52], ram[0x53] | ram[0x54] << 8)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

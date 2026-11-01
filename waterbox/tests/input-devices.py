#!/usr/bin/env python3
"""The input devices' test schedules, and what the input test cartridge
(tests/input-test) shows of them in its RAM. Used by run-gate.sh.

    input-devices.py schedule <device> <out.inputs>
        the run-native/run-wbx input file for <device>: fourScore, zapper,
        arkanoid, powerPadA, powerPadB, and the Famicom expansion port's
        famicomZapper, famicomArkanoid, fourPlayerAdapter, familyTrainerA,
        familyTrainerB, konamiHyperShot and partyTap (240 frames, every
        control moving)
    input-devices.py column <device> <index> <out.inputs>
        the device's button <index> alone held for the last 30 of 120
        frames (the button devices: the mats, the Hyper Shot, the Party Tap)
    input-devices.py buttons <device>
        how many buttons a button device has
    input-devices.py movie <device> <in.inputs> <out.txt>
        (<device> may also be "pad", a pad in port 1 and nothing else, or
        "fds", the same with the Disk System's drive)
        the same schedule as a Chimera movie for a project whose ports hold
        <device>: an entry's groups are the console's, then each player's,
        a group's axes first (5 wide and a comma), then its buttons' letters,
        and only the controls the machine has (the core's IsButtonActive and
        IsAxisActive)
    input-devices.py check <device> <in.inputs> <RAM dump>
        whether the RAM shows the schedule's last frame: the four pads and
        the Four Score's signatures; the Zapper's trigger; the Arkanoid
        controller's knob and button. The expansion port's devices answer
        on bit 1 (the four-player adapter, the Famicom Arkanoid controller)
        or as the Zapper does. Prints what it read; exit 1 if wrong.
    input-devices.py light <RAM dump>
        the cartridge's light reading: "<seen 0/1> <reads>"
"""
import sys

PAD_FIELD = "UDLRSsBA"   # the input file's order
WIRE = "ABsSUDLR"        # the package's order (and the cartridge's bits)
NEUTRAL = {"x": 32768, "y": 32768, "p": 80, "X": 32768, "Y": 32768, "k": 80}
FOUR = ("fourScore", "fourPlayerAdapter")
# the button devices (2026-11-01): their first wire index and how many
# buttons; the mats' squares are numbered as printed on them
BUTTON_DEVICES = {"powerPadA": (41, 12), "powerPadB": (41, 12), "familyTrainerA": (53, 12),
                  "familyTrainerB": (53, 12), "konamiHyperShot": (65, 4), "partyTap": (69, 6)}
LETTERS = {"powerPadA": "1234567890-=", "powerPadB": "1234567890-=", "familyTrainerA": "1234567890-=",
           "familyTrainerB": "1234567890-=", "konamiHyperShot": "qwoi", "partyTap": "!@#$%^"}


def schedule(device):
    lines = []
    for f in range(240):
        pads = []
        for p in range(4 if device in FOUR else 1):
            held = WIRE[(f // 8 + 2 * p) % 8]
            pads.append("".join(c if c == held else "." for c in PAD_FIELD))
        extra = ""
        if device == "zapper":
            extra = "@%sx=%d y=%d" % ("T " if (f // 5) % 2 else "", (f * 997) % 65536, (f * 2191) % 65536)
        elif device == "arkanoid":
            extra = "@%sp=%d" % ("F " if (f // 3) % 2 else "", (f * 7) % 161)
        elif device == "famicomZapper":
            extra = "@%sX=%d Y=%d" % ("t " if (f // 5) % 2 else "", (f * 997) % 65536, (f * 2191) % 65536)
        elif device == "famicomArkanoid":
            extra = "@%sk=%d" % ("f " if (f // 3) % 2 else "", (f * 7) % 161)
        elif device in BUTTON_DEVICES:
            first, n = BUTTON_DEVICES[device]
            held = ["b%d" % (first + i) for i in range(n) if (f // (2 + i)) % 3 == 1]
            extra = "@" + " ".join(held) if held else ""
        lines.append("|..|" + "|".join(pads) + "|" + (extra + "|" if extra else ""))
    return lines


def column(device, index, frames=120, hold=30):
    first, n = BUTTON_DEVICES[device]
    pad = "." * 8
    out = []
    for f in range(frames):
        extra = "@b%d|" % (first + index) if f >= frames - hold else ""
        out.append("|..|" + pad + "|" + extra)
    return out


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
        if tok in ("T", "F", "t", "f", "<", ">", "e") or tok[0] == "b":
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
        # the expansion port's controls are the console's group: its axes
        # first, then its buttons (Power, Reset, then the device's)
        if device == "famicomZapper":
            console = "%5d,%5d,%s%s" % (axes["X"], axes["Y"], console, "T" if "t" in held else ".")
        elif device == "famicomArkanoid":
            console = "%5d,%s%s" % (axes["k"], console, "F" if "f" in held else ".")
        if device == "fds":
            # the Disk System's drive: Previous Disk, Next Disk, Eject Disk
            console += "".join(c if c in held else "." for c in "<>e")
        if device in BUTTON_DEVICES and BUTTON_DEVICES[device][0] >= 53:
            # the expansion port's: the console's group, after the drive's
            first, n = BUTTON_DEVICES[device]
            console += "".join(LETTERS[device][i] if "b%d" % (first + i) in held else "." for i in range(n))
        groups = [console, pad(0)]
        if device in ("powerPadA", "powerPadB"):
            first, n = BUTTON_DEVICES[device]
            groups.append("".join(LETTERS[device][i] if "b%d" % (first + i) in held else "." for i in range(n)))
        if device in FOUR:
            groups += [pad(1), pad(2), pad(3)]
        elif device == "zapper":
            groups.append("%5d,%5d,%s" % (axes["x"], axes["y"], "T" if "T" in held else "."))
        elif device == "arkanoid":
            groups.append("%5d,%s" % (axes["p"], "F" if "F" in held else "."))
        out.append("|" + "|".join(groups) + "|")
    return out


def bits(ram, base, n, bit=0):
    return [(ram[base + i] >> bit) & 1 for i in range(n)]


def mat_bits(device, held):
    """the device's bits (Mesen's key numbers turned as on the mat's side)"""
    first, n = BUTTON_DEVICES[device]
    side_b = device in ("powerPadB", "familyTrainerB")
    k = [0] * 12
    for i in range(n):
        if "b%d" % (first + i) in held:
            k[(i // 4) * 4 + (3 - i % 4) if side_b else i] = 1
    return k


def check_buttons(device, ram, held):
    """what the raw reads of $4017 (RAM $30-$47) must be"""
    reads = [ram[0x30 + i] for i in range(24)]
    if device in ("powerPadA", "powerPadB"):
        k = mat_bits(device, held)
        lo = k[1] | k[0] << 1 | k[4] << 2 | k[8] << 3 | k[5] << 4 | k[9] << 5 | k[10] << 6 | k[6] << 7
        hi = k[3] | k[2] << 1 | k[11] << 2 | k[7] << 3 | 0xF0
        want = [(((hi >> i) & 1 if i < 8 else 1) << 4 | ((lo >> i) & 1 if i < 8 else 1) << 3) for i in range(24)]
        got = [r & 0x18 for r in reads]
    elif device in ("familyTrainerA", "familyTrainerB"):
        k = mat_bits(device, held)
        col = [k[i] | k[4 + i] | k[8 + i] for i in range(4)]
        v = ~(col[0] << 4 | col[1] << 3 | col[2] << 2 | col[3] << 1) & 0x1E
        want = [v] * 24
        got = [r & 0x1E for r in reads]
    elif device == "konamiHyperShot":
        b = [1 if "b%d" % (65 + i) in held else 0 for i in range(4)]
        v = b[1] << 1 | b[0] << 2 | b[3] << 3 | b[2] << 4
        want = [v] * 24
        got = [r & 0x1E for r in reads]
    else:
        st = sum(1 << i for i in range(6) if "b%d" % (69 + i) in held)
        want = [(st & 7) << 2, ((st >> 3) & 7) << 2] + [0x14] * 22
        got = [r & 0x1C for r in reads]
    return got, want


def check(device, lines, ram):
    console, pads, held, axes = parse(lines[-1])
    if device in BUTTON_DEVICES:
        got, want = check_buttons(device, ram, held)
        if got != want:
            print("$4017 read %s, not %s" % (" ".join("%02x" % g for g in got[:8]), " ".join("%02x" % w for w in want[:8])))
            return False
        print("$4017 read as the last frame's buttons give: %s" % " ".join("%02x" % g for g in got[:8]))
        return True
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
    elif device == "fourPlayerAdapter":
        # the same as the Four Score on bit 1, with the signatures swapped
        got = {"P1": bits(ram, 0x10, 8, 1), "P3": bits(ram, 0x18, 8, 1), "sig4016": bits(ram, 0x20, 8, 1),
               "P2": bits(ram, 0x30, 8, 1), "P4": bits(ram, 0x38, 8, 1), "sig4017": bits(ram, 0x40, 8, 1)}
        exp = {"P1": want(0), "P3": want(2), "sig4016": [0, 0, 1, 0, 0, 0, 0, 0],
               "P2": want(1), "P4": want(3), "sig4017": [0, 0, 0, 1, 0, 0, 0, 0]}
        for k in exp:
            if got[k] != exp[k]:
                problems.append("%s read %s, not %s" % (k, got[k], exp[k]))
        print("four pads and both signatures on bit 1 as the last frame holds them" if not problems else "; ".join(problems))
    elif device in ("zapper", "famicomZapper"):
        trig = (ram[0x30] >> 4) & 1
        if trig != (1 if ("T" if device == "zapper" else "t") in held else 0):
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
    elif device == "famicomArkanoid":
        # the knob's bits on bit 1 of $4017, inverted; the button on bit 1 of $4016
        knob = 0
        for b in bits(ram, 0x30, 8, 1):
            knob = (knob << 1) | (1 - b)
        fire = (ram[0x10] >> 1) & 1
        if knob != 0x54 + axes["k"]:
            problems.append("knob read 0x%02x, not 0x%02x" % (knob, 0x54 + axes["k"]))
        if fire != (1 if "f" in held else 0):
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
    elif cmd == "column":
        open(sys.argv[4], "w").write("\n".join(column(sys.argv[2], int(sys.argv[3]))) + "\n")
    elif cmd == "buttons":
        print(BUTTON_DEVICES[sys.argv[2]][1])
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

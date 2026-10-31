#!/usr/bin/env python3
"""The other machines' test schedules, their Chimera movies, and what the
test programs (tests/<system>-test) show of them in their RAM. Used by
waterbox/tests/systems.sh. A machine is named by its option of the setting
"machine" (snes, gb, ...); its controls are read from waterbox.config.

    systems.py wire <machine>
        '<console>,<pad>': how many console buttons and how many columns a
        pad has, for the harness's --wire
    systems.py pad <machine>
        the harness's --pad: where the pad exercise's A, B, Select, Start,
        Up, Down, Left and Right are on the machine's wire
    systems.py schedule <machine> <players> <frames> <out.inputs> [<from>]
        an input file that presses each button of each of the first
        <players> players in turn (each player one column ahead of the one
        before), nothing before frame <from> (default 0)
    systems.py hold <machine> <frames> <out.inputs> <frame>:<count>:<button>[,<button>]... ...
        an input file holding the named buttons ("P1 Start", "Power") from
        <frame> for <count> frames
    systems.py movie <machine> <players> <in.inputs> <out.txt>
        the same input as a Chimera movie for a project with <players> pads:
        an entry's groups are the console's, then each player's, each the
        held buttons' letters ('.' for one not held)
    systems.py colours <picture.tga>
        how many colours the picture has
    systems.py check <machine> <players> <in.inputs> <RAM dump>
        whether the test program's RAM shows the schedule's last frame for
        the first <players> pads; prints what it read, exit 1 if wrong
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "waterbox.config")


def machine(name):
    cfg = json.load(open(CONFIG))
    for m in cfg["machines"]:
        if name in m.get("when", []):
            inp = m.get("input") or cfg["input"]
            players = inp["players"]
            inPlayer = {b for p in players for b in p}
            console = [b for b in inp["buttons"] if b not in inPlayer]
            return inp, console, players
    sys.exit("no machine %s in waterbox.config" % name)


def wire(name):
    inp, console, players = machine(name)
    return len(console), len(players[0])


def pad_map(name):
    inp, console, players = machine(name)
    cols = [b.split(" ", 1)[1] for b in players[0]]
    # the exercise's columns, by what each machine calls them
    want = {"A": ["A", "I", "Button 2", "Right Button"], "B": ["B", "II", "Button 1", "Left Button"],
            "Select": ["Select"], "Start": ["Start", "Run"],
            "Up": ["Up", "X1"], "Down": ["Down", "X3"], "Left": ["Left", "X4"], "Right": ["Right", "X2"]}
    out = []
    for k in ("A", "B", "Select", "Start", "Up", "Down", "Left", "Right"):
        at = -1
        for alias in want[k]:
            if alias in cols:
                at = len(console) + cols.index(alias)
                break
        out.append(at)
    return out


def line(console_held, pads_held):
    return "|" + "".join("x" if h else "." for h in console_held) + "|" + \
        "|".join("".join("x" if h else "." for h in p) for p in pads_held) + "|"


def schedule(name, players, frames, start=0):
    inp, console, plist = machine(name)
    width = len(plist[0])
    out = []
    for f in range(frames):
        pads = []
        for p in range(len(plist)):
            held = [False] * width
            if p < players and f >= start:
                held[(f // 8 + p) % width] = True
            pads.append(held)
        out.append(line([False] * len(console), pads))
    return out


def hold(name, frames, specs):
    inp, console, plist = machine(name)
    width = len(plist[0])
    rows = [([False] * len(console), [[False] * width for _ in plist]) for _ in range(frames)]
    for spec in specs:
        at, count, buttons = spec.split(":", 2)
        for b in buttons.split(","):
            for f in range(int(at), min(frames, int(at) + int(count))):
                if b in console:
                    rows[f][0][console.index(b)] = True
                else:
                    p = next(i for i, pl in enumerate(plist) if b in pl)
                    rows[f][1][p][plist[p].index(b)] = True
    return [line(c, p) for c, p in rows]


def parse(text):
    fields = text.strip().strip("|").split("|")
    return [[c != "." for c in f] for f in fields]


def movie(name, players, lines):
    inp, console, plist = machine(name)
    mn = inp["mnemonics"]

    def letter(b):
        return mn.get(b) or mn.get(b.split(" ", 1)[1])
    out = []
    for text in lines:
        fields = parse(text)
        groups = ["".join(letter(b) if h else "." for b, h in zip(console, fields[0]))]
        for p in range(players):
            groups.append("".join(letter(b) if h else "." for b, h in zip(plist[p], fields[1 + p])))
        out.append("|" + "|".join(groups) + "|")
    return out


def held_names(name, text):
    inp, console, plist = machine(name)
    fields = parse(text)
    held = {b for b, h in zip(console, fields[0]) if h}
    for p, pl in enumerate(plist):
        held |= {b for b, h in zip(pl, fields[1 + p]) if h}
    return held


def check_snes(lines, ram, players):
    """$4218-$421F at RAM $10-$17: pads 1 and 2 (data line 1), 3 and 4 (data
    line 2), each a 16-bit word of B Y Select Start Up Down Left Right in the
    high byte and A X L R in the low byte's top nibble"""
    held = held_names("snes", lines[-1])
    order = ["B", "Y", "Select", "Start", "Up", "Down", "Left", "Right", "A", "X", "L", "R"]
    words = {1: (0x11, 0x10), 2: (0x13, 0x12), 3: (0x17, 0x16)}
    problems, seen = [], []
    for p, (hi, lo) in words.items():
        if p > players:
            continue
        w = ram[hi] << 8 | ram[lo]
        got = {b for i, b in enumerate(order) if w & (0x8000 >> i)}
        want = {b.split(" ", 1)[1] for b in held if b.startswith("P%d " % p)}
        seen.append("P%d %s" % (p, "+".join(sorted(got)) or "-"))
        if got != want:
            problems.append("P%d read %s, not %s" % (p, sorted(got), sorted(want)))
    # pads 4 and 5 by hand: bit 0 and bit 1 of the sixteen reads at $20
    for p, bit in ((4, 0), (5, 1)):
        if p > players:
            continue
        got = {b for i, b in enumerate(order) if (ram[0x20 + i] >> bit) & 1}
        want = {b.split(" ", 1)[1] for b in held if b.startswith("P%d " % p)}
        seen.append("P%d %s" % (p, "+".join(sorted(got)) or "-"))
        if got != want:
            problems.append("P%d read %s, not %s" % (p, sorted(got), sorted(want)))
    print("; ".join(problems) if problems else "the RAM holds the last frame's pads: " + ", ".join(seen))
    return not problems


def report(problems, seen):
    print("; ".join(problems) if problems else "the RAM holds the last frame's buttons: " + ", ".join(seen))
    return not problems


def held_cols(name, text, player):
    """the columns (names without the player) player <player> holds"""
    return {b.split(" ", 1)[1] for b in held_names(name, text) if b.startswith("P%d " % player)}


def check_gb(name):
    def check(lines, ram, players):
        """RAM $C000 (WRAM's first byte): Down Up Left Right Start Select B A
        from the highest bit"""
        order = ["Down", "Up", "Left", "Right", "Start", "Select", "B", "A"]
        got = {b for i, b in enumerate(order) if ram[0] & (0x80 >> i)}
        want = held_cols(name, lines[-1], 1)
        return report([] if got == want else ["P1 read %s, not %s" % (sorted(got), sorted(want))],
                      ["P1 " + ("+".join(sorted(got)) or "-")])
    return check


def check_sms(name):
    def check(lines, ram, players):
        """the two ports' bytes at RAM +0 and +1; the Game Gear's Start at +2"""
        port = ram[0] | ram[1] << 8
        p1 = {b for i, b in enumerate(["Up", "Down", "Left", "Right", "Button 1", "Button 2"]) if port & (1 << i)}
        p2 = {b for i, b in enumerate(["Up", "Down", "Left", "Right", "Button 1", "Button 2"]) if port & (1 << (6 + i))}
        problems, seen = [], []
        want1 = held_cols(name, lines[-1], 1)
        if name == "gg":
            if ram[2] & 0x80:
                p1.add("Start")
        if p1 != want1:
            problems.append("P1 read %s, not %s" % (sorted(p1), sorted(want1)))
        seen.append("P1 " + ("+".join(sorted(p1)) or "-"))
        if players > 1:
            want2 = held_cols(name, lines[-1], 2)
            if p2 != want2:
                problems.append("P2 read %s, not %s" % (sorted(p2), sorted(want2)))
            seen.append("P2 " + ("+".join(sorted(p2)) or "-"))
        return report(problems, seen)
    return check


CV_KEYS = {0xD: "Key 1", 0x7: "Key 2", 0xC: "Key 3", 0x2: "Key 4", 0x3: "Key 5", 0xE: "Key 6", 0x5: "Key 7",
           0x1: "Key 8", 0xB: "Key 9", 0xA: "Key 0", 0x9: "Key *", 0x6: "Key #"}


def check_cv(lines, ram, players):
    """each controller in joystick mode (RAM +0, +1) and keypad mode (+2,
    +3), inverted: the joystick's Up Right Down Left on bits 0-3 and the
    left button on bit 6; the keypad's key code on bits 0-3 (one key) and
    the right button on bit 6"""
    problems, seen = [], []
    for p in range(1, players + 1):
        joy, pad = ram[p - 1], ram[p + 1]
        got = {b for b, bit in (("Up", 0), ("Right", 1), ("Down", 2), ("Left", 3), ("Left Button", 6)) if joy & (1 << bit)}
        if pad & 0x40:
            got.add("Right Button")
        code = (~pad) & 0x0F
        if code != 0xF:
            got.add(CV_KEYS.get(code, "key code %x" % code))
        want = held_cols("coleco", lines[-1], p)
        if got != want:
            problems.append("P%d read %s, not %s" % (p, sorted(got), sorted(want)))
        seen.append("P%d %s" % (p, "+".join(sorted(got)) or "-"))
    return report(problems, seen)


CHECKS = {"snes": check_snes, "sgb": check_snes, "gb": check_gb("gb"), "gbc": check_gb("gbc"),
          "sms": check_sms("sms"), "gg": check_sms("gg"), "sg1000": check_sms("sg1000"), "coleco": check_cv}


def colours(path):
    """how many colours a picture the harness wrote (--screenshot) has"""
    d = open(path, "rb").read()
    w, h = d[12] | d[13] << 8, d[14] | d[15] << 8
    px = d[18:18 + w * h * 4]
    return len({px[i:i + 3] for i in range(0, len(px), 4)})


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "wire":
        print("%d,%d" % wire(sys.argv[2]))
    elif cmd == "pad":
        print(",".join(str(i) for i in pad_map(sys.argv[2])))
    elif cmd == "schedule":
        start = int(sys.argv[6]) if len(sys.argv) > 6 else 0
        rows = schedule(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), start)
        open(sys.argv[5], "w").write("\n".join(rows) + "\n")
    elif cmd == "hold":
        rows = hold(sys.argv[2], int(sys.argv[3]), sys.argv[5:])
        open(sys.argv[4], "w").write("\n".join(rows) + "\n")
    elif cmd == "movie":
        lines = [l for l in open(sys.argv[4]) if l.strip()]
        open(sys.argv[5], "w").write("\n".join(movie(sys.argv[2], int(sys.argv[3]), lines)) + "\n")
    elif cmd == "colours":
        print(colours(sys.argv[2]))
    elif cmd == "check":
        lines = [l for l in open(sys.argv[4]) if l.strip()]
        ram = open(sys.argv[5], "rb").read()
        sys.exit(0 if CHECKS[sys.argv[2]](lines, ram, int(sys.argv[3])) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

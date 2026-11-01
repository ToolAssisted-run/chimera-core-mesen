#!/usr/bin/env python3
"""The other machines' devices beyond the pad: their test schedules, their
Chimera movies, and what the test programs show of them in their RAM. Used
by waterbox/tests/systems.sh (the NES's devices are input-devices.py's).

A device is one of:
    snesMouse1    the Super NES Mouse in port 1 (a pad in port 2)
    snesMouse2    the mouse in port 2 (a pad in port 1)
    superScope    the Super Scope in port 2 (a pad in port 1)
    lightPhaser1  the Master System's Light Phaser in port 1 (a pad in 2)
    lightPhaser2  the Light Phaser in port 2 (a pad in port 1)
    avenuePad6    the PC Engine's six-button Avenue Pad 6
    avenuePad6Tap five Avenue Pad 6s through the multitap
and DEVICES below says each one's machine, settings, test program and RAM.

    machine-devices.py info <device>
        "<machine> <test program> <settings JSON> <domain>"
    machine-devices.py schedule <device> <frames> <out.inputs>
        the run-native/run-wbx input file: every control of the device
        moving, and the active pads' buttons one after another (the same
        file runs on the machine with plain pads in the device's place: the
        device's controls are then nobody's)
    machine-devices.py column <device> <frames> <index> <out.inputs>
        only the device's button <index> (in the order of its buttons) held,
        for the last 30 of <frames> frames (the Super Scope's on the frame
        before the last only: they act on a press), its axes at rest
    machine-devices.py buttons <device>
        how many buttons the device has
    machine-devices.py movie <device> <in.inputs> <out.txt>
        the same as a Chimera movie for a project whose ports hold the
        device: an entry's groups are the console's, then each player's, a
        group's axes first (5 wide and a comma), then its buttons' letters,
        and only the controls the machine has (IsButtonActive, IsAxisActive)
    machine-devices.py check <device> <in.inputs> <RAM dump> [column]
        whether the RAM shows the schedule's last frames (see check()); prints
        what it read, exit 1 if wrong
    machine-devices.py hold <device> <frames> <out.inputs> <buttons> <axes>
        the input file of a window check: the named buttons (comma
        separated, "" for none) held and the named axes (name:value, comma
        separated) set on every frame, nothing else
    machine-devices.py neutral <device>
        the harness's --neutral for the device's machine
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import systems  # noqa: E402

# device -> machine, settings, test program, RAM domain, the players whose pads
# are active, the device's buttons (wire names), the device's axes as
# (axis index, name, how it moves in the schedule)
DEVICES = {
    "snesMouse1": ("snes", {"machine": "snes", "snesPort1": "mouse"}, "snes-devices.sfc", "WRAM", [2],
                   ["P1 Mouse Left", "P1 Mouse Right"], [(0, "P1 Mouse X", "rel"), (1, "P1 Mouse Y", "rel")]),
    "snesMouse2": ("snes", {"machine": "snes", "snesPort2": "mouse"}, "snes-devices.sfc", "WRAM", [1],
                   ["P2 Mouse Left", "P2 Mouse Right"], [(2, "P2 Mouse X", "rel"), (3, "P2 Mouse Y", "rel")]),
    "superScope": ("snes", {"machine": "snes", "snesPort2": "superScope"}, "snes-devices.sfc", "WRAM", [1],
                   ["P2 Super Scope Fire", "P2 Super Scope Cursor", "P2 Super Scope Turbo", "P2 Super Scope Pause"],
                   [(4, "P2 Super Scope X", "abs"), (5, "P2 Super Scope Y", "abs")]),
    "lightPhaser1": ("sms", {"machine": "sms", "smsPort1": "lightPhaser"}, "sms-phaser.sms", "Work RAM", [2],
                     ["P1 Trigger"], [(0, "P1 Light Phaser X", "abs"), (1, "P1 Light Phaser Y", "abs")]),
    "lightPhaser2": ("sms", {"machine": "sms", "smsPort2": "lightPhaser"}, "sms-phaser.sms", "Work RAM", [1],
                     ["P2 Trigger"], [(2, "P2 Light Phaser X", "abs"), (3, "P2 Light Phaser Y", "abs")]),
    "avenuePad6": ("pce", {"machine": "pce", "pcePad": "avenuePad6"}, "pce-pad6.pce", "Work RAM", [1],
                   ["P1 III", "P1 IV", "P1 V", "P1 VI"], []),
    "avenuePad6Tap": ("pce", {"machine": "pce", "pcePort": "multitap", "pcePad": "avenuePad6"}, "pce-pad6.pce",
                      "Work RAM", [1, 2, 3, 4, 5],
                      ["P%d %s" % (p, b) for p in range(1, 6) for b in ("III", "IV", "V", "VI")], []),
}

NEUTRAL = {"snes": [0, 0, 0, 0, 32768, 32768], "sms": [32768, 32768, 32768, 32768, 32768, 32768]}


def info(device):
    return DEVICES[device]


def wire_index(device, name):
    m = DEVICES[device][0]
    for at, b in systems.devices(m):
        if b == name:
            return at
    sys.exit("%s is not on the %s wire" % (name, m))


def axis_value(kind, f, k):
    """an axis's value at frame f (k: which axis of the device)"""
    if kind == "rel":
        # a mouse's movement: every size and both ways, now and then none
        v = ((f * (37 + 16 * k)) % 255) - 127
        return 0 if f % 11 == 5 else v
    return (f * (997 + 1194 * k)) % 65536


def line(device, f, held_buttons, axes, pads_on=True):
    """an input line: the machine's console field, every player's pad field
    (the active players' pads moving), and the '@' field"""
    m, settings, rom, domain, players, buttons, axdefs = DEVICES[device]
    inp, console, pads = systems.machine(m)
    width = len(pads[0])
    fields = ["." * len(console)]
    for p in range(len(pads)):
        if pads_on and (p + 1) in players:
            col = (f // 8 + p) % width
            fields.append("".join("x" if c == col else "." for c in range(width)))
        else:
            fields.append("." * width)
    extra = ["b%d" % wire_index(device, b) for b in held_buttons]
    extra += ["a%d=%d" % (i, v) for i, v in axes]
    return "|" + "|".join(fields) + "|" + ("@" + " ".join(extra) + "|" if extra else "")


def schedule(device, frames):
    m, settings, rom, domain, players, buttons, axdefs = DEVICES[device]
    out = []
    for f in range(frames):
        held = [b for i, b in enumerate(buttons) if (f // (3 + 2 * i)) % 2 == 1]
        if device == "superScope":
            # Turbo switches its mode when pressed; Pause is a press: both
            # now and then only
            held = [b for b in held if not b.endswith(("Turbo", "Pause"))]
            if f % 60 in (20, 21):
                held.append("P2 Super Scope Turbo")
            if f % 45 == 30:
                held.append("P2 Super Scope Pause")
        axes = [(i, axis_value(kind, f, k)) for k, (i, name, kind) in enumerate(axdefs)]
        out.append(line(device, f, held, axes))
    return out


def column(device, frames, index, hold=30):
    m, settings, rom, domain, players, buttons, axdefs = DEVICES[device]
    neutral = NEUTRAL.get(m, [0] * 6)
    out = []
    for f in range(frames):
        held = [buttons[index]] if f >= frames - hold else []
        if device == "superScope":
            # its buttons act on a press: pressed on the one frame the
            # program's last read shows (the frame before the last)
            held = [buttons[index]] if f == frames - 2 else []
        axes = [(i, neutral[i]) for i, name, kind in axdefs]
        out.append(line(device, f, held, axes, pads_on=False))
    return out


def parse(text):
    """an input line -> (console, [pads as lists of 0/1], held wire indices, {axis: value})"""
    fields = text.strip().strip("|").split("|")
    extra = ""
    if fields[-1].startswith("@"):
        extra = fields.pop()[1:]
    held, axes = set(), {}
    for tok in extra.split():
        if tok[0] == "b":
            held.add(int(tok[1:]))
        else:
            k, v = tok[1:].split("=")
            axes[int(k)] = int(v)
    return fields[0], [[c != "." for c in f] for f in fields[1:]], held, axes


def movie(device, lines):
    """the movie for a project whose ports hold the device: per group (the
    console's, then each player's) the active axes, then the active
    buttons, in the order the package's player lists give"""
    m, settings, rom, domain, players, buttons, axdefs = DEVICES[device]
    inp, console, pads = systems.machine(m)
    mn = inp["mnemonics"]
    neutral = NEUTRAL.get(m, [0] * 6)
    axis_index = {a["name"]: i for i, a in enumerate(inp.get("axes", []))}
    dev_buttons = set(buttons)
    dev_axes = {name for i, name, kind in axdefs}

    def letter(b):
        return mn.get(b) or mn.get(b.split(" ", 1)[1])
    out = []
    for text in lines:
        cfield, pfields, held, axes = parse(text)
        groups = ["".join(letter(b) if c != "." else "." for b, c in zip(console, cfield))]
        for p, plist in enumerate(inp["players"]):
            active_pad = (p + 1) in players
            ax, bt = [], []
            for name in plist:
                if name in axis_index:
                    if name in dev_axes:
                        ax.append("%5d," % axes.get(axis_index[name], neutral[axis_index[name]]))
                    continue
                if name in dev_buttons:
                    bt.append(letter(name) if wire_index(device, name) in held else ".")
                elif name in pads[p] and active_pad:
                    bt.append(letter(name) if pfields[p][pads[p].index(name)] else ".")
            if ax or bt:
                groups.append("".join(ax) + "".join(bt))
            elif active_pad:
                groups.append("")
        out.append("|" + "|".join(groups) + "|")
    return out


def bits(ram, at, n, bit=0):
    return [(ram[at + i] >> bit) & 1 for i in range(n)]


def byte_of(bitlist):
    v = 0
    for b in bitlist:
        v = (v << 1) | b
    return v


def check(device, lines, ram, column=False):
    """The test programs read the controls at the start of a frame (in the
    vertical blank), and Mesen takes the frame's controls at its end, so the
    RAM after a run holds the controls of the frame before the last one."""
    m, settings, rom, domain, players, buttons, axdefs = DEVICES[device]
    parsed = [parse(t) for t in lines]
    problems, seen = [], []

    def is_held(name, at):
        return wire_index(device, name) in parsed[at][2]

    def axis(i, at):
        return parsed[at][3].get(i, NEUTRAL.get(m, [0] * 6)[i])

    if device in ("snesMouse1", "snesMouse2"):
        at = -2
        port = 1 if device == "snesMouse1" else 2
        lo, hi = (0x10, 0x11) if port == 1 else (0x12, 0x13)
        manual = 0x40 if port == 1 else 0x50
        b1, b2 = ram[hi], ram[lo]
        b3, b4 = byte_of(bits(ram, manual, 8)), byte_of(bits(ram, manual + 8, 8))
        ax_x, ax_y = axdefs[0][0], axdefs[1][0]
        # that frame's movement, at most 127 each way; the sign flags keep
        # the last way it moved (Mesen's SnesMouse)
        dx, dy = axis(ax_x, at), axis(ax_y, at)
        left = up = 0
        for _, _, h, a in parsed[:len(parsed) + at + 1]:
            if a.get(ax_x, 0):
                left = 0x80 if a[ax_x] < 0 else 0
            if a.get(ax_y, 0):
                up = 0x80 if a[ax_y] < 0 else 0
        want3 = min(abs(dy), 127) | up
        want4 = min(abs(dx), 127) | left
        L, R = is_held("P%d Mouse Left" % port, at), is_held("P%d Mouse Right" % port, at)
        want2 = 0x01 | (0x40 if L else 0) | (0x80 if R else 0)
        if b1 != 0 or b2 != want2:
            problems.append("bytes 1-2 read %02x %02x, not 00 %02x (signature, buttons L=%d R=%d)" % (b1, b2, want2, L, R))
        if b3 != want3 or b4 != want4:
            problems.append("movement read %02x %02x, not %02x %02x (dy %d, dx %d)" % (b3, b4, want3, want4, dy, dx))
        seen.append("port %d mouse: buttons %02x, movement %02x %02x (dx %d, dy %d)" % (port, b2, b3, b4, dx, dy))
    elif device == "superScope":
        at = -2
        word = ram[0x13] << 8 | ram[0x12]
        fire, cursor, turbo, pause, off = (word >> 15) & 1, (word >> 14) & 1, (word >> 13) & 1, (word >> 12) & 1, (word >> 9) & 1
        if word & 0xFF != 0xFF:
            problems.append("signature read %02x, not ff" % (word & 0xFF))
        # Cursor is a level; Fire fires on its press (Turbo off); Turbo
        # switches a mode at each press; Pause is a press
        upto = len(parsed) + at + 1
        presses = sum(1 for i in range(1, upto) if is_held("P2 Super Scope Turbo", i) and not is_held("P2 Super Scope Turbo", i - 1))
        want = {"cursor": int(is_held("P2 Super Scope Cursor", at)), "turbo": presses % 2,
                "pause": int(is_held("P2 Super Scope Pause", at) and not is_held("P2 Super Scope Pause", at - 1)),
                "offscreen": 0,
                "fire": int(is_held("P2 Super Scope Fire", at) and (presses % 2 or not is_held("P2 Super Scope Fire", at - 1)))}
        got = {"cursor": cursor, "turbo": turbo, "pause": pause, "offscreen": off, "fire": fire}
        for k in want:
            if got[k] != want[k]:
                problems.append("%s read %d, not %d" % (k, got[k], want[k]))
        # where it pointed: Mesen has the picture chip latch the beam at x +
        # 10 and y - 3 when Fire or Cursor is held
        h = ram[0x61] | (ram[0x62] & 1) << 8
        v = ram[0x63] | (ram[0x64] & 1) << 8
        lat = at
        if is_held("P2 Super Scope Fire", lat) or is_held("P2 Super Scope Cursor", lat):
            x = axis(4, lat) * 256 // 65536
            y = axis(5, lat) * 224 // 65536 + 7
            if not ram[0x60] & 0x40 or (h, v) != (x + 10, max(0, y - 3)):
                problems.append("the beam latched at %d,%d (flag %d), not %d,%d" % (h, v, (ram[0x60] >> 6) & 1, x + 10, max(0, y - 3)))
            seen.append("pointed at %d,%d, latched at %d,%d" % (x, y, h, v))
        elif not column:
            problems.append("the schedule holds neither Fire nor Cursor where the check looks")
        seen.append("Super Scope bits fire %d cursor %d turbo %d pause %d" % (fire, cursor, turbo, pause))
    elif device in ("lightPhaser1", "lightPhaser2"):
        at = -2
        port = 1 if device == "lightPhaser1" else 2
        trig = (ram[0] >> 4) & 1 if port == 1 else (ram[1] >> 2) & 1
        if trig != int(is_held("P%d Trigger" % port, at)):
            problems.append("trigger read %d" % trig)
        # the light: on the line the gun points at, or within the five after
        # it (Mesen's SmsLightPhaser), on this port's bit; the H counter
        # latched where it points (SmsVdp: x + 38, kept in 8 bits)
        line_seen, bitbyte, hcount = ram[6], ram[7], ram[8]
        x = axis(axdefs[0][0], at) * 256 // 65536
        y = axis(axdefs[1][0], at) * 192 // 65536
        c = (((x + 38) & 0xFF) + 3) >> 1
        want_h = (c + 0x55) & 0xFF if c > 0x93 else c
        bit, other = (0x40, 0x80) if port == 1 else (0x80, 0x40)
        if line_seen == 0xFF:
            problems.append("no light seen (pointed at line %d)" % y)
        elif not (y <= line_seen <= y + 5) or bitbyte & bit or not bitbyte & other:
            problems.append("light seen on line %d with $DD %02x, pointed at line %d with port %d" % (line_seen, bitbyte, y, port))
        if hcount != want_h:
            problems.append("H counter %02x, not %02x (pointed at x %d)" % (hcount, want_h, x))
        seen.append("trigger %d, light on line %d (pointed at %d,%d), H counter %02x" % (trig, line_seen, x, y, hcount))
    elif device in ("avenuePad6", "avenuePad6Tap"):
        at = -2
        cfield, pfields, held, axes = parsed[at]
        # each pass of the program reads one half of each pad; the half with
        # no direction held (the six-button signature) holds III IV V VI
        names_normal = {4: "Up", 5: "Right", 6: "Down", 7: "Left", 0: "I", 1: "II", 2: "Select", 3: "Run"}
        names_six = {0: "III", 1: "IV", 2: "V", 3: "VI"}
        for p in players:
            a, b = ram[0x10 + p - 1], ram[0x18 + p - 1]
            six, normal = (a, b) if a & 0xF0 == 0xF0 and b & 0xF0 != 0xF0 else (b, a)
            if six & 0xF0 != 0xF0:
                problems.append("P%d: neither read has the six-button signature (%02x %02x)" % (p, a, b))
                continue
            got = {n for bit, n in names_normal.items() if normal & (1 << bit)}
            got |= {n for bit, n in names_six.items() if six & (1 << bit)}
            want = {b.split(" ", 1)[1] for b in buttons if b.startswith("P%d " % p) and is_held(b, at)}
            pad = systems.machine(m)[2][p - 1]
            want |= {n.split(" ", 1)[1] for n, h in zip(pad, pfields[p - 1]) if h}
            if got != want:
                problems.append("P%d read %s, not %s" % (p, sorted(got), sorted(want)))
            seen.append("P%d %s" % (p, "+".join(sorted(got)) or "-"))
    print("; ".join(problems) if problems else "the RAM shows the controls: " + "; ".join(seen))
    return not problems


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "info":
        m, settings, rom, domain = DEVICES[sys.argv[2]][:4]
        print(m, rom, json.dumps(settings, separators=(",", ":")), domain.replace(" ", "_"))
    elif cmd == "schedule":
        open(sys.argv[4], "w").write("\n".join(schedule(sys.argv[2], int(sys.argv[3]))) + "\n")
    elif cmd == "column":
        rows = column(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        open(sys.argv[5], "w").write("\n".join(rows) + "\n")
    elif cmd == "buttons":
        print(len(DEVICES[sys.argv[2]][5]))
    elif cmd == "movie":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        open(sys.argv[4], "w").write("\n".join(movie(sys.argv[2], lines)) + "\n")
    elif cmd == "check":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        col_mode = len(sys.argv) > 5 and sys.argv[5] == "column"
        sys.exit(0 if check(sys.argv[2], lines, open(sys.argv[4], "rb").read(), col_mode) else 1)
    elif cmd == "hold":
        dev, frames = sys.argv[2], int(sys.argv[3])
        m = DEVICES[dev][0]
        names = {a["name"]: i for i, a in enumerate(systems.machine(m)[0].get("axes", []))}
        held = [b for b in sys.argv[5].split(",") if b]
        axes = []
        for spec in [x for x in sys.argv[6].split(",") if x]:
            name, value = spec.rsplit(":", 1)
            axes.append((names[name], int(value)))
        rows = [line(dev, f, held, axes, pads_on=False) for f in range(frames)]
        open(sys.argv[4], "w").write("\n".join(rows) + "\n")
    elif cmd == "neutral":
        print(",".join(str(v) for v in NEUTRAL.get(DEVICES[sys.argv[2]][0], [0] * 6)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

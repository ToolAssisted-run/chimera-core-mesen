#!/usr/bin/env python3
"""The NES devices of 2026-11-01: their test schedules, their Chimera
movies, and what the device test cartridges (tests/input-test/
make-nes-devices.py) must keep in RAM, worked out from what Mesen's devices
answer (Core/NES/Input, Core/SNES/Input). Used by run-gate.sh (the
dev:<device> and engine:nes-devices checks) and the frontend test. The
devices before them are input-devices.py's.

    nes-devices.py list
        the devices, one a line
    nes-devices.py info <device>
        "<test cartridge> <settings JSON>"
    nes-devices.py schedule <device> <frames> <out.inputs>
        the run-native/run-wbx input file: every control of the device
        moving (and the pads its ports also hold)
    nes-devices.py column <device> <frames> <index> <out.inputs>
        only the device's button <index> held, for the last 30 frames
    nes-devices.py buttons <device>
        how many buttons the device has
    nes-devices.py movie <device> <in.inputs> <out.txt>
        the same as a Chimera movie for a project whose ports hold the
        device: an entry's groups are the console's, then each player's, a
        group's axes first (5 wide and a comma), then its buttons' letters,
        only the controls the machine has (waterbox.config's order and
        players, the device's active controls below)
    nes-devices.py check <device> <in.inputs> <RAM dump>
        whether the RAM holds what the device answers to the cartridge's
        reads on the last frame (the whole schedule is played through the
        device's model, for devices that keep a state: the mice, the
        Pachinko controller's knob); prints what it read, exit 1 if wrong
    nes-devices.py hold <device> <frames> <out.inputs> <buttons> <axes>
        an input file holding the named buttons (wire names, comma
        separated, "" for none) and the named axes (name:value) on every
        frame: the window test's
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "waterbox.config")

PAD = ["A", "B", "Select", "Start", "Up", "Down", "Left", "Right"]
PAD_FIELD = "UDLRSsBA"        # the input file's pad field order
PAD_WIRE = "ABsSUDLR"         # the wire's order, as letters of the field
KEYPAD = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#", ".", "C", "End"]


def cfg():
    return json.load(open(CONFIG))


def wire():
    return cfg()["input"]["buttons"]


def axes_decl():
    return cfg()["input"]["axes"]


def p(n, names):
    return ["P%d %s" % (n, x) for x in names]


FB_KEYS = None
SUBOR_KEYS = None


def fb_keys():
    return [b for b in wire() if b.startswith("Key ")]


def subor_keys():
    return [b for b in wire() if b.startswith("Subor Key ")]


# device -> (cartridge, settings, players whose pads are part of it,
#            the device's own buttons (wire names), its axes (names),
#            the pads its ports also hold: players moving in the schedule)
def devices():
    w = wire()
    mahjong = [b for b in w if b.startswith("Expansion Mahjong ")]
    boxing = ["Expansion Left Hook", "Expansion Move Right", "Expansion Move Left", "Expansion Right Hook",
              "Expansion Left Jab", "Expansion Body", "Expansion Right Jab", "Expansion Straight"]
    return {
        "suborMouse1": ("nes-serial", {"port1": "suborMouse"}, [], p(1, ["Mouse Left", "Mouse Right"]),
                        ["P1 Mouse X", "P1 Mouse Y"], []),
        "suborMouse2": ("nes-serial", {"port2": "suborMouse"}, [], p(2, ["Mouse Left", "Mouse Right"]),
                        ["P2 Mouse X", "P2 Mouse Y"], [1]),
        "snesMouseNes1": ("nes-serial", {"port1": "snesMouse"}, [], p(1, ["Mouse Left", "Mouse Right"]),
                          ["P1 Mouse X", "P1 Mouse Y"], []),
        "snesMouseNes2": ("nes-serial", {"port2": "snesMouse"}, [], p(2, ["Mouse Left", "Mouse Right"]),
                          ["P2 Mouse X", "P2 Mouse Y"], [1]),
        "virtualBoy1": ("nes-serial", {"port1": "virtualBoy"}, [1],
                        p(1, ["L", "R", "Pad 2 Up", "Pad 2 Down", "Pad 2 Left", "Pad 2 Right"]), [], []),
        "virtualBoy2": ("nes-serial", {"port2": "virtualBoy"}, [2],
                        p(2, ["L", "R", "Pad 2 Up", "Pad 2 Down", "Pad 2 Left", "Pad 2 Right"]), [], [1]),
        "snesPadNes1": ("nes-serial", {"port1": "snesPad"}, [1], p(1, ["X", "Y", "L", "R"]), [], []),
        "snesPadNes2": ("nes-serial", {"port2": "snesPad"}, [2], p(2, ["X", "Y", "L", "R"]), [], [1]),
        "nttKeypad1": ("nes-serial", {"port1": "nttKeypad"}, [1],
                       p(1, ["X", "Y", "L", "R"]) + p(1, ["Keypad " + k for k in KEYPAD]), [], []),
        "nttKeypad2": ("nes-serial", {"port2": "nttKeypad"}, [2],
                       p(2, ["X", "Y", "L", "R"]) + p(2, ["Keypad " + k for k in KEYPAD]), [], [1]),
        "famicomMic": ("nes-serial", {"port2": "famicomPad"}, [2], ["P2 Microphone"], [], [1]),
        "twoPlayerAdapter": ("nes-serial", {"port1": "none", "expansion": "twoPlayerAdapter"}, [1, 2], [], [], []),
        "pachinko": ("nes-serial", {"port1": "none", "expansion": "pachinko"}, [1],
                     ["Expansion Pachinko Press", "Expansion Pachinko Release"], [], []),
        "fcns": ("nes-serial", {"port1": "none", "expansion": "fcns"}, [1],
                 p(1, ["Keypad " + k for k in KEYPAD]), [], []),
        "horiTrack": ("nes-serial", {"port1": "none", "expansion": "horiTrack"}, [1], [],
                      ["Expansion Track X", "Expansion Track Y"], []),
        "bandaiHyperShot": ("nes-serial", {"port1": "none", "expansion": "bandaiHyperShot"}, [1],
                            ["Expansion Trigger"], ["Expansion Zapper X", "Expansion Zapper Y"], []),
        "oekaKids": ("nes-oeka", {"expansion": "oekaKids"}, [], ["Expansion Pen"],
                     ["Expansion Pen X", "Expansion Pen Y"], [1]),
        "excitingBoxing": ("nes-boxing", {"expansion": "excitingBoxing"}, [], boxing, [], [1]),
        "jissenMahjong": ("nes-mahjong", {"expansion": "jissenMahjong"}, [], mahjong, [], [1]),
        "familyBasic": ("nes-fbkey", {"expansion": "familyBasicKeyboard"}, [], fb_keys(), [], [1]),
        "suborKeyboard": ("nes-suborkey", {"expansion": "suborKeyboard"}, [], subor_keys(), [], [1]),
        "bandaiMic": ("nes-mic", {}, [], ["Microphone A", "Microphone B", "Microphone Voice"], [], [1]),
    }


def info(dev):
    return devices()[dev]


def axis_index(name):
    for i, a in enumerate(axes_decl()):
        if a["name"] == name:
            return i
    sys.exit("no axis " + name)


def axis_neutral(name):
    return axes_decl()[axis_index(name)]["neutral"]


def btn_index(name):
    return wire().index(name)


def axis_value(name, f):
    """an axis's value at frame f in a schedule"""
    a = axes_decl()[axis_index(name)]
    k = axis_index(name)
    if a["min"] < 0:
        # a movement: every size both ways, now and then none
        v = ((f * (37 + 16 * k)) % 255) - 127
        return 0 if f % 11 == 5 else v
    return (f * (997 + 1194 * k)) % 65536


def line(held, axes, pads):
    """an input line: pads (a list of sets of the wire's pad names held for
    players 1 to 4, as many as given), and the '@' field: the other held
    buttons (wire names) and the axes (name -> value)"""
    fields = []
    for s in pads:
        fields.append("".join(c if {"U": "Up", "D": "Down", "L": "Left", "R": "Right", "S": "Start",
                                     "s": "Select", "B": "B", "A": "A"}[c] in s else "." for c in PAD_FIELD))
    if not fields:
        fields = ["." * 8]
    extra = ["b%d" % btn_index(b) for b in held]
    extra += ["a%d=%d" % (axis_index(n), v) for n, v in axes.items()]
    return "|..|" + "|".join(fields) + "|" + ("@" + " ".join(extra) + "|" if extra else "")


def schedule(dev, frames):
    rom, settings, padsOf, buttons, axes, others = info(dev)
    out = []
    players = sorted(set(padsOf) | set(others))
    for f in range(frames):
        pads = []
        for pl in range(1, (max(players) if players else 1) + 1):
            if pl in players:
                pads.append({PAD[(f // 8 + 2 * pl) % 8]})
            else:
                pads.append(set())
        held = [b for i, b in enumerate(buttons) if (f // (2 + i % 7) + i) % 3 == 1]
        if dev in ("famicomMic", "bandaiMic") and f == frames - 1:
            # the microphones are heard on some frames only: the last frame
            # holds every button, and is one that hears them
            held = list(buttons)
        ax = {n: axis_value(n, f) for n in axes}
        if f == frames - 1:
            # the last frame, which the check reads: movements small enough
            # for every device's count (the Subor mouse's 31, the Hori
            # Track's 7), each way, X and Y apart
            for n in axes:
                if axes_decl()[axis_index(n)]["min"] < 0:
                    ax[n] = -5 if n.endswith("X") else 6
        out.append(line(held, ax, pads))
    return out


def column(dev, frames, index, hold=30):
    rom, settings, padsOf, buttons, axes, others = info(dev)
    out = []
    names = device_buttons(dev)
    for f in range(frames):
        held = names[index] if f >= frames - hold else None
        pads = [set(), set()]
        extra = []
        if held is not None:
            if held.startswith("P") and held[1].isdigit() and held.split(" ", 1)[1] in PAD:
                pads[int(held[1]) - 1].add(held.split(" ", 1)[1])
            else:
                extra.append(held)
        out.append(line(extra, {}, pads))
    return out


def device_buttons(dev):
    """every button the device has, its pads' first"""
    rom, settings, padsOf, buttons, axes, others = info(dev)
    return [b for pl in padsOf for b in p(pl, PAD)] + buttons


def parse(text):
    """an input line -> (set of held wire names, {axis name: value})"""
    fields = text.strip().strip("|").split("|")
    held = set()
    axes = {a["name"]: a["neutral"] for a in axes_decl()}
    console = fields[0]
    if "P" in console:
        held.add("Power")
    if "r" in console:
        held.add("Reset")
    pl = 0
    letter = {"U": "Up", "D": "Down", "L": "Left", "R": "Right", "S": "Start", "s": "Select", "B": "B", "A": "A"}
    w = wire()
    names = [a["name"] for a in axes_decl()]
    for fld in fields[1:]:
        if fld.startswith("@"):
            for tok in fld[1:].split():
                if tok[0] == "b":
                    held.add(w[int(tok[1:])])
                elif tok[0] == "a":
                    k, v = tok[1:].split("=")
                    axes[names[int(k)]] = int(v)
                elif tok == "T":
                    held.add("P2 Trigger")
                elif tok == "t":
                    held.add("Expansion Trigger")
            continue
        pl += 1
        for c in fld:
            if c != ".":
                held.add("P%d %s" % (pl, letter[c]))
    return held, axes


def active(dev):
    """the controls a project with the device has: (buttons, axes), wire names"""
    rom, settings, padsOf, buttons, axes, others = info(dev)
    pads = sorted(set(padsOf) | set(others))
    act = {"Power", "Reset"} | set(b for pl in pads for b in p(pl, PAD)) | set(buttons)
    if dev == "fcns":
        act |= set(p(1, ["Keypad " + k for k in KEYPAD]))
    return act, set(axes)


def movie(dev, lines):
    c = cfg()["input"]
    act, axact = active(dev)
    groups = [[]] + [[] for _ in c["players"]]
    owner = {}
    for gi, members in enumerate(c["players"]):
        for m in members:
            owner[m] = gi + 1
    gaxes = [[] for _ in groups]
    for a in c["axes"]:
        if a["name"] in axact:
            gaxes[owner.get(a["name"], 0)].append(a["name"])
    for b in c["buttons"]:
        if b in act:
            groups[owner.get(b, 0)].append(b)
    mn = c["mnemonics"]

    def letter(b):
        if b in mn:
            return mn[b]
        bare = b.split(" ", 1)[1] if b[0] == "P" and b[1].isdigit() else b
        return mn[bare]
    out = []
    for text in lines:
        held, axes = parse(text)
        parts = []
        for gi in range(len(groups)):
            if not groups[gi] and not gaxes[gi]:
                if gi == 0:
                    parts.append("")
                continue
            s = "".join("%5d," % axes[n] for n in gaxes[gi])
            s += "".join(letter(b) if b in held else "." for b in groups[gi])
            parts.append(s)
        # players with nothing active still need their place when a later
        # player has something: Chimera writes every player up to the last
        # active one
        out.append("|" + "|".join(parts) + "|")
    return out


# ---- what Mesen's devices answer ----

OPEN = 0x40  # the bus's undriven lines after "LDA $4016": $40, its high byte


def nes_byte(held, pl):
    b = 0
    for i, n in enumerate(PAD):
        if "P%d %s" % (pl, n) in held:
            b |= 1 << i
    return b


def serial_reads(bits, nbits, fill, count=32, shift_right=True):
    """the reads of a device that shifts its state out on one line: a list
    of 0/1"""
    out = []
    state = bits
    for _ in range(count):
        if shift_right:
            out.append(state & 1)
            state = (state >> 1) | (fill << (nbits - 1))
        else:
            out.append((state >> (nbits - 1)) & 1)
            state = ((state << 1) | fill) & ((1 << nbits) - 1)
    return out


def snes_pad_bits(held, pl):
    names = ["B", "Y", "Select", "Start", "Up", "Down", "Left", "Right", "A", "X", "L", "R"]
    v = 0
    for i, n in enumerate(names):
        if "P%d %s" % (pl, n) in held:
            v |= 1 << i
    return v


def ntt_bits(held, pl):
    v = snes_pad_bits(held, pl) | 1 << 13
    for i, k in enumerate(KEYPAD):
        if "P%d Keypad %s" % (pl, k) in held:
            v |= 1 << (16 + i if i < 14 else 31)
    return v


def vb_bits(held, pl):
    order = ["Pad 2 Down", "Pad 2 Left", "Select", "Start", "Up", "Down", "Left", "Right", "Pad 2 Right",
             "Pad 2 Up", "L", "R", "B", "A"]
    v = 1 << 14
    for i, n in enumerate(order):
        if "P%d %s" % (pl, n) in held:
            v |= 1 << i
    return v


class Mouse:
    """the Super NES Mouse and the Subor mouse as Mesen keeps them"""
    def __init__(self, kind):
        self.kind = kind
        self.held = (0, 0)       # movement the device holds, not yet taken
        self.up = self.left = 0  # the SNES mouse's last directions
        self.packet = [0, 0, 0]
        self.pos = 0
        self.size = 1
        self.state = 0

    def frame(self, dx, dy):
        self.held = (self.held[0] + dx, self.held[1] + dy)

    def strobe(self, left, right):
        mx, my = self.held
        if self.kind == "snes":
            self.held = (0, 0)
            if mx:
                self.left = 0x80 if mx < 0 else 0
            if my:
                self.up = 0x80 if my < 0 else 0
            ax, ay = min(abs(mx), 127), min(abs(my), 127)
            b2 = 0x01 | (0x40 if left else 0) | (0x80 if right else 0)
            self.state = (b2 << 16) | ((ay | self.up) << 8) | (ax | self.left)
            return
        if self.pos < self.size - 1:
            self.pos += 1
            self.state = self.packet[self.pos]
            return
        self.held = (0, 0)
        upf = 0x80 if my < 0 else 0
        lf = 0x80 if mx < 0 else 0
        ax, ay = min(abs(mx), 31), min(abs(my), 31)
        btn = (0x80 if left else 0) | (0x40 if right else 0)
        if ax <= 1 and ay <= 1:
            self.packet = [btn | ((0x30 if lf else 0x10) if ax else 0) | ((0x0C if upf else 0x04) if ay else 0), 0, 0]
            self.size = 1
        else:
            self.packet = [btn | (0x20 if lf else 0) | (ax & 0x10) | (0x08 if upf else 0) | ((ay & 0x10) >> 2) | 0x01,
                           ((ax & 0x0F) << 2) | 0x02, ((ay & 0x0F) << 2) | 0x03]
            self.size = 3
        self.pos = 0
        self.state = self.packet[0]

    def reads(self):
        if self.kind == "snes":
            return serial_reads(self.state, 32, 1, 32, shift_right=False)
        return serial_reads(self.state, 8, 0, 32, shift_right=False)


def expected(dev, lines, nmis=None):
    """the bytes the cartridge keeps on the last frame, and a mask of the
    bits that are the device's (the rest is the bus or other devices).
    nmis: how many frames the cartridge read the device in (its frame
    count, RAM $00): the last ones; before them it was still starting, and
    a device that keeps a state saw no strobe"""
    rom, settings, padsOf, buttons, axes, others = info(dev)
    frames = [parse(t) for t in lines]
    first = len(frames) - nmis if nmis is not None else 0
    held, ax = frames[-1]
    if rom == "nes-serial":
        seg = []  # three strobes: [(4016 values, 4017 values, masks)]
        if dev.startswith("suborMouse") or dev.startswith("snesMouseNes"):
            pl = 1 if dev.endswith("1") else 2
            m = Mouse("subor" if dev.startswith("subor") else "snes")
            for fi, (fh, fa) in enumerate(frames):
                m.frame(fa["P%d Mouse X" % pl], fa["P%d Mouse Y" % pl])
                strobes = []
                for k in range(3 if fi >= first else 0):
                    m.strobe("P%d Mouse Left" % pl in fh, "P%d Mouse Right" % pl in fh)
                    strobes.append(m.reads())
            return port_bytes(strobes, pl)
        if dev.startswith("virtualBoy"):
            pl = 1 if dev.endswith("1") else 2
            r = serial_reads(vb_bits(held, pl), 16, 1)
            return port_bytes([r] * 3, pl)
        if dev.startswith("snesPadNes"):
            pl = 1 if dev.endswith("1") else 2
            r = serial_reads(snes_pad_bits(held, pl), 16, 1)
            return port_bytes([r] * 3, pl)
        if dev.startswith("nttKeypad"):
            pl = 1 if dev.endswith("1") else 2
            r = serial_reads(ntt_bits(held, pl), 32, 1)
            return port_bytes([r] * 3, pl)
        if dev == "famicomMic":
            # the microphone on bit 2 of every $4016 read, while held on every
            # third frame (Mesen's frame count, one more than the frame's
            # place in the run, a multiple of 3), as Mesen gives it from a key
            mic = 1 if "P2 Microphone" in held and len(frames) % 3 == 0 else 0
            # and the second controller's pad on bit 0 of $4017
            r2 = serial_reads(nes_byte(held, 2), 8, 1)
            want, mask = [], []
            for k in range(3):
                want += [mic << 2] * 32 + r2
                mask += [0x04] * 32 + [0x01] * 32
            return want, mask
        if dev == "twoPlayerAdapter":
            r1 = serial_reads(nes_byte(held, 1), 8, 1)
            r2 = serial_reads(nes_byte(held, 2), 8, 1)
            want, mask = [], []
            for k in range(3):
                want += [b << 1 for b in r1] + [b << 1 for b in r2]
                mask += [0x02] * 64
            return want, mask
        if dev == "pachinko":
            analog = 0
            for fi, (fh, fa) in enumerate(frames):
                strobes = []
                for k in range(3 if fi >= first else 0):
                    if analog < 0x63 and "Expansion Pachinko Press" in fh:
                        analog += 1
                    elif analog > 0 and "Expansion Pachinko Release" in fh:
                        analog -= 1
                    rev = int("{:08b}".format(analog)[::-1], 2)
                    st = (nes_byte(fh, 1) | ((~rev & 0xFF) << 8)) & 0xFFFF
                    strobes.append(serial_reads(st, 16, 0))
            return exp_bytes(strobes)
        if dev == "fcns":
            v = nes_byte(held, 1)
            for i, k in enumerate(KEYPAD):
                if "P1 Keypad " + k in held:
                    v |= 1 << (8 + i if i < 14 else 23)
            r = serial_reads(v, 24, 1)
            return exp_bytes([r] * 3)
        if dev == "horiTrack":
            def nib(v):
                v = max(-8, min(v, 7)) & 0x0F
                return ((v & 8) >> 3) | ((v & 4) >> 1) | ((v & 2) << 1) | ((v & 1) << 3)
            held_mov = [0, 0]
            for fi, (fh, fa) in enumerate(frames):
                held_mov[0] += fa["Expansion Track X"]
                held_mov[1] += fa["Expansion Track Y"]
                strobes = []
                for k in range(3 if fi >= first else 0):
                    dx, dy = held_mov
                    held_mov = [0, 0]
                    b1 = (~nib(dy) & 0x0F) | ((~nib(dx) & 0x0F) << 4)
                    st = nes_byte(fh, 1) | (b1 << 8) | (0x09 << 16)
                    strobes.append(serial_reads(st, 24, 0))
            return exp_bytes(strobes)
        if dev == "bandaiHyperShot":
            r = serial_reads(nes_byte(held, 1), 8, 0)
            trig = 0x10 if "Expansion Trigger" in held else 0
            want, mask = [], []
            for k in range(3):
                # in the vertical blank the gun sees no light: bit 3 set
                # (bit 3, the light: the reads run on past the vertical
                # blank into the picture; dev:bandaiHyperShot-light checks it)
                want += [b << 1 for b in r] + [trig] * 32
                mask += [0x02] * 32 + [0x10] * 32
            return want, mask
    if rom == "nes-oeka":
        x = ax["Expansion Pen X"] * 256 // 65536
        y = ax["Expansion Pen Y"] * 240 // 65536
        click = "Expansion Pen" in held
        touch = click or y >= 48
        xp = int(max(0, x + 8) / 256.0 * 240) & 0xFF
        yp = int(max(0, y - 14) / 240.0 * 256) & 0xFF
        st = (xp << 10) | (yp << 2) | (2 if touch else 0) | (1 if click else 0)
        want = []
        for i in range(18):
            st = (st << 1) & 0xFFFFFFFF
            bit = 0x00 if st & 0x40000 else 0x08
            want += [bit, 0x04]
        return want, [0x0C] * 36
    if rom == "nes-boxing":
        b = [1 if n in held else 0 for n in buttons]
        v0 = (0 if b[0] else 2) | (0 if b[1] else 4) | (0 if b[2] else 8) | (0 if b[3] else 0x10)
        v1 = (0 if b[4] else 2) | (0 if b[5] else 4) | (0 if b[6] else 8) | (0 if b[7] else 0x10)
        return [v0, v1], [0x1E, 0x1E]
    if rom == "nes-mahjong":
        b = {n.split(" ", 2)[2]: (n in held) for n in buttons}
        rows = {
            1: [(0x04, "N"), (0x08, "M"), (0x10, "L"), (0x20, "K"), (0x40, "J"), (0x80, "I")],
            2: [(0x01, "H"), (0x02, "G"), (0x04, "F"), (0x08, "E"), (0x10, "D"), (0x20, "C"), (0x40, "B"), (0x80, "A")],
            3: [(0x02, "Ron"), (0x04, "Riichi"), (0x08, "Chii"), (0x10, "Pon"), (0x20, "Kan"), (0x40, "Start"),
                (0x80, "Select")],
        }
        want = []
        for row in (1, 2, 3):
            st = sum(bit for bit, n in rows[row] if b[n])
            want += [x << 1 for x in serial_reads(st, 8, 0, 8)]
        return want, [0x02] * 24
    if rom == "nes-fbkey":
        names = fb_keys()
        matrix = ["F8", "Return", "[", "]", "Kana", "Right Shift", "Yen", "Stop", "F7", "@", ":", ";", "_", "/", "-",
                  "^", "F6", "O", "L", "K", ".", ",", "P", "0", "F5", "I", "U", "J", "M", "N", "9", "8", "F4", "Y",
                  "G", "H", "B", "V", "7", "6", "F3", "T", "R", "D", "F", "C", "5", "4", "F2", "W", "S", "A", "X",
                  "Z", "E", "3", "F1", "Esc", "Q", "Ctrl", "Left Shift", "Grph", "1", "2", "Clr Home", "Up", "Right",
                  "Left", "Down", "Space", "Del", "Ins"]
        pressed = set(n[4:] for n in names if n in held)
        want = []
        for row in range(10):
            for col in (0, 1):
                if row == 9:
                    keys = 0
                else:
                    keys = 0
                    base = row * 8 + col * 4
                    for i in range(4):
                        if matrix[base + i] in pressed:
                            keys |= 0x10
                        keys >>= 1
                want.append((~keys << 1) & 0x1E)
        return want, [0x1E] * 20
    if rom == "nes-suborkey":
        names = subor_keys()
        enum = [n[len("Subor Key "):] for n in names]
        matrix = ["4", "G", "F", "C", "F2", "E", "5", "V",
                  "2", "D", "S", "End", "F1", "W", "3", "X",
                  "Insert", "Backspace", "Page Down", "Right", "F8", "Page Up", "Delete", "Home",
                  "9", "I", "L", ",", "F5", "O", "0", ".",
                  "]", "Enter", "Up", "Left", "F7", "[", "\\", "Down",
                  "Q", "Caps Lock", "Z", "Tab", "Esc", "A", "1", "Ctrl",
                  "7", "Y", "K", "M", "F4", "U", "8", "J",
                  "-", ";", "'", "/", "F6", "P", "=", "Shift",
                  "T", "H", "N", "Space", "F3", "R", "6", "B",
                  "Keypad 6", "Keypad Enter", "Keypad 4", "Keypad 8", None, "Unknown 1", "Unknown 2", "Unknown 3",
                  "Alt", "Keypad 4", "Keypad 7", "F11", "F12", "Keypad 1", "Keypad 2", "Keypad 8",
                  "Keypad -", "Keypad +", "Keypad *", "Keypad 9", "F10", "Keypad 5", "Keypad /", "Num Lock",
                  "`", "Keypad 6", "Pause", "Space", "F9", "Keypad 3", "Keypad .", "Keypad 0"]
        pressed = set(n[len("Subor Key "):] for n in names if n in held)
        assert all(m is None or m in enum for m in matrix), [m for m in matrix if m is not None and m not in enum]
        want = []
        for row in range(13):
            for col in (0, 1):
                base = row * 8 + col * 4
                keys = 0
                for i in range(4):
                    if matrix[base + i] is not None and matrix[base + i] in pressed:
                        keys |= 1 << i
                if row == 9 and col:
                    keys |= 1
                want.append((~keys << 1) & 0x1E)
        return want, [0x1E] * 26
    if rom == "nes-mic":
        a = "Microphone A" in held
        b = "Microphone B" in held
        # the voice, while held, on every second frame (Mesen's frame count
        # even), as Mesen gives it from a key
        v = "Microphone Voice" in held and len(frames) % 2 == 0
        return [(0 if a else 1) | (0 if b else 2) | (4 if v else 0)], [0x07]
    sys.exit("no model for " + dev)


def port_bytes(strobes, pl):
    """three strobes' reads of one port's device: bit 0 of $4016 (port 1)
    or $4017 (port 2)"""
    want, mask = [], []
    for r in strobes:
        if pl == 1:
            want += r + [0] * 32
            mask += [1] * 32 + [0] * 32
        else:
            want += [0] * 32 + r
            mask += [0] * 32 + [1] * 32
    return want, mask


def exp_bytes(strobes):
    """three strobes' reads of an expansion port device on bit 1 of $4016"""
    want, mask = [], []
    for r in strobes:
        want += [b << 1 for b in r] + [0] * 32
        mask += [0x02] * 32 + [0] * 32
    return want, mask


def check(dev, lines, ram):
    want, mask = expected(dev, lines, ram[0])
    got = list(ram[0x200:0x200 + len(want)])
    bad = [i for i in range(len(want)) if (got[i] & mask[i]) != (want[i] & mask[i])]
    if bad:
        i = bad[0]
        print("byte %d read %02x, not %02x (the device's bits %02x); %d bytes differ" % (
            i, got[i], want[i] & mask[i] | (got[i] & ~mask[i] & 0xFF), mask[i], len(bad)))
        return False
    print("the cartridge read what the device answers: %s" % " ".join("%02x" % (got[i] & mask[i]) for i in range(min(8, len(want)))))
    return True


def hold(dev, frames, buttons, axes):
    held = [b for b in buttons.split(",") if b]
    ax = {}
    for a in axes.split(","):
        if a:
            n, v = a.rsplit(":", 1)
            ax[n] = int(v)
    pads = [set(), set(), set(), set()]
    extra = []
    for b in held:
        if b[0] == "P" and b[1].isdigit() and b.split(" ", 1)[1] in PAD:
            pads[int(b[1]) - 1].add(b.split(" ", 1)[1])
        else:
            extra.append(b)
    while len(pads) > 1 and not pads[-1]:
        pads.pop()
    return [line(extra, ax, pads)] * frames


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "list":
        print("\n".join(devices()))
    elif cmd == "info":
        rom, settings = info(sys.argv[2])[:2]
        print(rom + ".nes", json.dumps(settings, separators=(",", ":")))
    elif cmd == "schedule":
        open(sys.argv[4], "w").write("\n".join(schedule(sys.argv[2], int(sys.argv[3]))) + "\n")
    elif cmd == "column":
        open(sys.argv[5], "w").write("\n".join(column(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))) + "\n")
    elif cmd == "buttons":
        print(len(device_buttons(sys.argv[2])))
    elif cmd == "movie":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        open(sys.argv[4], "w").write("\n".join(movie(sys.argv[2], lines)) + "\n")
    elif cmd == "check":
        lines = [l for l in open(sys.argv[3]) if l.strip()]
        sys.exit(0 if check(sys.argv[2], lines, open(sys.argv[4], "rb").read()) else 1)
    elif cmd == "hold":
        open(sys.argv[4], "w").write("\n".join(hold(sys.argv[2], int(sys.argv[3]), sys.argv[5], sys.argv[6])) + "\n")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

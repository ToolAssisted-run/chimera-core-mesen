#!/usr/bin/env python3
"""Write an input schedule for run-native and run-wbx (gate-harness.h's format).

    make-schedule.py <out> <frames> [event ...]

An event is "<first frame>:<frames held>:<what>", frames counted from 0:
  - "p<N>=<letters>": player N's pad (1 to 4) holds those of U D L R S s B A;
  - "@<item>": an item of the '@' field (T, F, x=N, y=N, p=N, t, f, X=N,
    Y=N, k=N, and the Disk System's <, > and e);
  - "P" or "r": Power or Reset.
Every line has four pad fields, so players 3 and 4 can be pressed."""
import sys


def main():
    out, total = sys.argv[1], int(sys.argv[2])
    events = []
    for a in sys.argv[3:]:
        first, length, what = a.split(":", 2)
        events.append((int(first), int(length), what))
    lines = []
    for f in range(total):
        pads = [["."] * 8 for _ in range(4)]
        extra, power, reset = [], ".", "."
        for first, length, what in events:
            if not first <= f < first + length:
                continue
            if what.startswith("p") and "=" in what:
                n, letters = what[1:].split("=", 1)
                for ch in letters:
                    pads[int(n) - 1]["UDLRSsBA".index(ch)] = ch
            elif what.startswith("@"):
                extra.append(what[1:])
            elif what == "P":
                power = "P"
            elif what == "r":
                reset = "r"
            else:
                sys.exit("unknown event " + what)
        line = "|" + power + reset + "|" + "|".join("".join(p) for p in pads) + "|"
        if extra:
            line += "@" + " ".join(extra) + "|"
        lines.append(line)
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

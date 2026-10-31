#!/usr/bin/env python3
"""Proper nouns in this core's language tables are never translated or bent
(owner, 2026-10-31).

Mesen, NES, EPSM, YMF288 and every other name of a program, chip, machine,
game or company stay exactly as they are written, in all 26 tables. A
language whose grammar puts endings on names says the sentence with a
common noun beside the name instead ("emulatoru Mesen", "Mesen-emulaattorin",
"YMF288-piirin"). A particle in another script (Korean, Japanese) is
grammar and leaves the name whole; a compound joined by a hyphen
("NES-Spiel", "EPSM-rummut") leaves it whole too.

Chimera's tools/check-proper-nouns.py knows only Chimera's own names; this
knows this core's as well (NAMES below, and the coreName of
waterbox.config), and also catches the endings that a sign joins to a name:
"YMF288:n", "EPSM's", "Mesen'in", "EPSM-et".

For every table but English's it says:
- each name the English text holds that is not in the translation as
  itself, with no letter on either side;
- each name with letters glued to it, directly or after an apostrophe or a
  colon, or a short lower-case ending after a hyphen.
English's own table is checked for letters glued directly to a name only
(its possessive "Mesen's" is English).

    waterbox/tests/check-names.py [<languages folder>]

Prints each one as "<language> <key>: ..." and exits 1 when there is any.
"""
import json
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "languages")

# This core's names, then Chimera's (tools/check-proper-nouns.py).
NAMES = ["Mesen", "MesenCE", "NES", "iNES", "NES 2.0", "UNIF", "Famicom", "Nintendo", "EPSM", "YMF288", "YM2608",
         "Yamaha", "Dendy", "NTSC", "PAL", "Zapper", "Four Score", "Arkanoid", "Vaus", "Taito", "Disk System", "BIOS",
         "Chimera", "TAStudio", "GitHub", "Lua", "Windows", "Linux", "macOS", "OpenGL", "Vulkan", "Direct3D", "SQLite",
         "miniBox", "ffmpeg", "Qt", "Wayland"]
try:
    with open(os.path.join(here, "..", "waterbox.config"), encoding="utf-8") as f:
        core_name = json.load(f).get("coreName")
    if core_name and core_name not in NAMES:
        NAMES.append(core_name)
except (OSError, ValueError):
    pass

# letters of the scripts the tables use that write names among their words:
# Latin with its accents (Vietnamese's too), Greek, Cyrillic
LETTER = "A-Za-zÀ-ɏḀ-ỿͰ-ϿЀ-ӿ"


def whole(name):
    return re.compile("(?<![" + LETTER + "])" + re.escape(name) + "(?![" + LETTER + "])")


def glued(name, strict):
    pattern = "[" + LETTER + "]" + re.escape(name) + "|" + re.escape(name) + "[" + LETTER + "]"
    if strict:
        # an ending joined by a sign: YMF288:n, EPSM's, Mesen'in, EPSM-et
        pattern += "|" + re.escape(name) + "['’:][" + LETTER + "]"
        pattern += "|" + re.escape(name) + "-[a-zß-ɏ]{1,3}(?![" + LETTER + "])"
    return re.compile(pattern)


# a file's name or an identifier is not a name in a sentence:
# ym2608_adpcm_rom.bin, battery.sav, .nes
FILE = re.compile(r"[\w-]*\.\w[\w.]*|\w+_\w+")


def texts(path):
    """a table's texts, a key's plural forms as one text"""
    with open(path, encoding="utf-8") as f:
        table = json.load(f)["texts"]
    return {k: " | ".join(v.values()) if isinstance(v, dict) else v for k, v in table.items()}


def masked(text, name):
    """the text with the longer names that hold this one taken out
    (NES in iNES, Mesen in MesenCE), and file names"""
    text = FILE.sub(" ", text)
    for other in NAMES:
        if other != name and name in other:
            text = whole(other).sub(" ", text)
    return text


english = texts(os.path.join(folder, "en.json"))
names_in = {k: [n for n in NAMES if whole(n).search(masked(v, n))] for k, v in english.items()}
bad = 0
for file_name in sorted(os.listdir(folder)):
    if not file_name.endswith(".json"):
        continue
    code = file_name[:-5]
    strict = code != "en"
    for key, text in sorted(texts(os.path.join(folder, file_name)).items()):
        one_line = text.replace("\n", " ")
        if strict:
            for n in names_in.get(key, []):
                if not whole(n).search(masked(text, n)):
                    print("%s %s: %s is not there as itself: %s" % (code, key, n, one_line))
                    bad += 1
        for n in NAMES:
            m = glued(n, strict).search(masked(text, n))
            if m:
                print("%s %s: %s is bent (\"%s\"): %s" % (code, key, n, m.group(0), one_line))
                bad += 1
print("%d bent or missing names in %d tables" % (bad, len([f for f in os.listdir(folder) if f.endswith(".json")])),
      file=sys.stderr)
sys.exit(1 if bad else 0)

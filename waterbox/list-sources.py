#!/usr/bin/env python3
"""Prints the upstream sources this core compiles, one per line, sorted.

Usage: list-sources.py <MesenCE checkout>

Everything of Mesen's emulator library is built: Core (all of its systems,
the debugger, netplay), Utilities, SevenZip and Lua - the same set Mesen's
own makefile links into MesenCore.so. Left out are the frontends: InteropDLL
(the C# UI's entry points), Sdl, Linux, Windows, MacOS, UI, and the two
Utilities files that load a shader library at run time (librashader).
"""
import os
import sys

root = sys.argv[1]
out = []
for top in ("Core", "Utilities", "SevenZip", "Lua"):
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
        dirnames.sort()
        for name in filenames:
            if top in ("Core", "Utilities") and not name.endswith((".cpp", ".c")):
                continue
            if top in ("SevenZip", "Lua") and not name.endswith(".c"):
                continue
            out.append(os.path.relpath(os.path.join(dirpath, name), root))
for path in sorted(out):
    print(path)

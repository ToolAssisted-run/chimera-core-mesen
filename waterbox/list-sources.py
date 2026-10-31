#!/usr/bin/env python3
"""Prints the upstream sources this core compiles, one per line, sorted.

Usage: list-sources.py <MesenCE checkout>

Everything of Mesen's emulator library is built: Core (all of its systems,
the debugger, netplay), Utilities, SevenZip and Lua - the same set Mesen's
own makefile links into MesenCore.so. Left out are the frontends: InteropDLL
(the C# UI's entry points), Sdl, Linux, Windows, MacOS, UI, and the two
Utilities files that load a shader library at run time (librashader).

Left out too is every piece of network code, which the build option
MESEN_NO_NETWORK (patches/0006) leaves unused: netplay (Core/Netplay), the
socket class it runs on (Utilities/Socket.cpp) and luasocket, the socket
library inside Mesen's Lua (LUASOCKET below). Chimera has no network code,
and a core built here has none either.
"""
import os
import sys

# luasocket's sources in Lua/; the rest of Lua/ is Lua itself
LUASOCKET = {"auxiliar.c", "buffer.c", "compat.c", "except.c", "inet.c", "io.c", "luasocket.c", "mime.c",
             "options.c", "select.c", "serial.c", "tcp.c", "timeout.c", "udp.c", "unix.c", "unixdgram.c",
             "unixstream.c", "usocket.c", "wsocket.c"}

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
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel.startswith(os.path.join("Core", "Netplay") + os.sep) or rel == os.path.join("Utilities", "Socket.cpp"):
                continue
            if top == "Lua" and name in LUASOCKET:
                continue
            out.append(rel)
for path in sorted(out):
    print(path)

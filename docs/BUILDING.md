# Building the Mesen core

This repository builds MesenCE as a sandboxed guest (`core.wbx`) and
packages it as one file, `mesen.chimeraCore`, which Chimera loads as the
NES and as each other system Mesen emulates that the package offers so far
(the Super NES and the Super Game Boy), picked by a project's setting
`machine`.

Two placeholders are used throughout:

- `<chimera>` is the absolute path of a Chimera checkout
  (https://github.com/ToolAssisted-run/chimera), built (its engine,
  `chimera-run` and the window) for the checks that run through it.
- `<minibox>` is `<chimera>/extern/chimera-common-minibox`, the miniBox
  submodule of that checkout: the sandbox host and the guest toolchain.

## Requirements

- Linux on x86_64.
- git, python3, meson, ninja, and the distribution's gcc and g++ (the guest
  is compiled by the same gcc through miniBox's musl specs file):

  ```
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential python3
  ```

- miniBox built with its C++ guest toolchain, in `<minibox>/build/meson-cpp`
  (Mesen is C++). That build downloads the GCC source that matches the
  installed gcc once, to build libstdc++ for the guest:

  ```
  git -C <chimera> submodule update --init extern/chimera-common-minibox
  meson setup <minibox>/build/meson-cpp <minibox> -Dguest_cpp=true
  meson compile -C <minibox>/build/meson-cpp
  ```

- For the frontend test only: Chimera built with its window
  (`<chimera>/tools/ci-chimera.sh`, which puts Qt 6.12 in `~/qt` unless told
  otherwise).

Mesen is large (409 source files). A build of one flavor takes a few
minutes at `-j4`; compile with a memory cap on a shared machine.

## Sources

```
git clone <this repository> chimera-core-mesen
cd chimera-core-mesen
git submodule update --init
```

`extern/MesenCE` is pinned to an unmodified MesenCE commit (4b8a196e,
2026-10-07). `meson.build` runs `waterbox/apply-patches.sh` at every
configure, which applies `patches/*.patch` to the submodule's working tree:
all of them on a clean tree, none on a tree that already has the last one
(the marker in `patches/series-marker`), and it refuses a tree with other
changes. After a build `git status` shows the submodule as modified: that
is the patches.

## The native reference and the sandbox driver

```
meson setup build/meson-native -Dminibox_dir=<minibox>
ninja -C build/meson-native
```

- `run-native` is the reference: Mesen and `waterbox/mesen.cpp` built for
  the host, with no sandbox.
- `run-wbx` runs `core.wbx` through miniBox's host library
  (`<minibox>/build/meson-cpp/source/host/libminiboxhost.so`) and prints the
  same digests.

Both take a work folder holding what a project would mount (the cartridge
under its name, `slots`, `settings`, firmware under its id) and the options
listed in `waterbox/gate-harness.h` (`--frames`, `--inputs`, `--exercise`,
`--dump-domain`, `--savedata-out`, `--turbo`, `--stall`, `--audio-out`;
`run-wbx` adds `--rerecord`, `--save-at`, `--load-at`).

## The guest

```
sh waterbox/setup-guest.sh -m <minibox>
ninja -C build/meson-guest
```

`setup-guest.sh` writes the meson cross file `build/guest-cross.ini`
(paths of this machine; not committed) and configures `build/meson-guest`.
The result is `build/meson-guest/core.wbx` (about 13 MB).

## The package

```
./waterbox/build-package.sh -m <minibox> -o <folder>
./waterbox/build-package.sh -r <chimera>
```

`-o` writes `mesen.chimeraCore` into any folder; `-r` writes it into
`<chimera>/build/Cores` (and takes miniBox from that checkout). The script
builds `core.wbx` if needed, checks it with miniBox's `check-wbx.sh` (no
thread-local storage, no `%fs`, nothing below the stack pointer), stages the
declarations, the language tables, the controller picture and the licence
texts, stamps `version` and `versionDate` (the commit and its date; `CORE_VERSION`
overrides the commit, as CI does), writes the zip twice and stops if the two
differ.

## The tests

### The core test script

```
./waterbox/run-gate.sh
```

It needs `run-native`, `run-wbx` and `core.wbx` built, and builds nothing
(it builds the Super NES chip test cartridges it needs into its work
folder). It ends with `<n> ok, <m> failed`; without Chimera it is 53
checks, and SKIP lines for the checks that need Chimera or the owner's
files. The other machines' checks are in `waterbox/tests/systems.sh`, which
it sources. With

```
CHIMERA_ROOT=<chimera> MESEN_PACKAGE=<the package> ./waterbox/run-gate.sh
```

more run: Chimera's own checks of the texts, and the ones through
`<chimera>/build/dll/chimera-run`: 62 checks. With all of the owner's files
(below) and `MESEN_PUBLISHED_PACKAGE`, 90.

`MESEN_PUBLISHED_PACKAGE=<mesen.chimeraCore as published>` (the NES-only
package, before the other machines) adds `nes:published` (its core.wbx and
this one run Nova's schedule to the same machine) and `engine:nes-published`
(a project and movie made with it play the same in this package).

### The other machines' games and BIOS files (optional, local only)

`MESEN_SYSTEMS_CONTENT=<folder>` names a folder laid out as the owner keeps
them: `systems/<system>/<game>` and `firmware/<file>`, under their own
names. The checks that use them (`waterbox/tests/systems.sh`, and the
window's in `run-frontend.sh`) say SKIP when a file is absent:

| File | Checks |
| --- | --- |
| `firmware/SNES_dsp1.rom` ... `SNES_st018.rom` (8 files) | `snes:chip-<chip>` |
| `systems/snes/`: Super Mario World, TheLastSuper, Top Gear 2, Sailor Moon S, Prince of Persia (J) | `snes:game:*`, `snes:game-frontend` |
| `systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb` with `firmware/SNES_SGB2_(J).sfc` and `SNES_SGB_RevB_(World).sfc` | `sgb:game:*`, `engine:sgb`, `sgb:frontend` |

### The owner's NES games and BIOS files (optional, local only)

Commercial games and BIOS files are never in this repository. Put them in a
folder under their own names and name it with `MESEN_CONTENT_DIR`:

```
MESEN_CONTENT_DIR=<folder> CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh
MESEN_CONTENT_DIR=<folder> ./waterbox/tests/run-frontend.sh --chimera-root <chimera>
```

| File | Checks |
| --- | --- |
| `ym2608_adpcm_rom.bin` (SHA-1 50b6c3e2...) | `epsm:real-rhythm`, `engine:epsm-firmware`, `epsm:frontend`, and the Sonic checks |
| `Sonic The Hedgehog (FAMICOM 60 PIN GAME).nes` | `game:sonic-epsm`, `engine:sonic-epsm`, `sonic:frontend` |
| `Ai Senshi Nicol (Japan).fds` and `FDS_disksys-nintendo.rom` (SHA-1 57fe1bde...) | `game:fds-nicol`, `engine:fds-nicol`, `fds:frontend` |
| `Duck Hunt (World).nes` or `Duck Hunt.zip` | `game:duckhunt` |
| `Arkanoid (U) [!].nes`, `Arkanoid II (Japan).nes` | `game:arkanoid`, `game:arkanoid2` |
| `R.C. Pro-Am II (U) [!].nes`, `Danny Sullivan's Indy Heat (U) [!].nes` | `game:rcproam2`, `game:indyheat` |

Each check says SKIP when its files are absent. Their schedules are
written by `waterbox/tests/make-schedule.py`; `docs/PLAN.md` says what each
compares.

### EPSM songs made with FamiStudio (optional)

FamiStudio (https://famistudio.org, MIT) exports a song to a playable
.nes cartridge whose sound engine drives the EPSM. Such cartridges are EPSM
music made by a tool other than this repository's. None is in this
repository. Export some (FamiStudio's command line, from its help:
`FamiStudio <song.fms> rom-export <out.nes> -rom-export-mode:ntsc`, or
`pal`), put them in a folder, and name it:

```
MESEN_FAMISTUDIO_ROMS=<folder> CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh
MESEN_FAMISTUDIO_ROMS=<folder> ./waterbox/tests/run-frontend.sh --chimera-root <chimera>
```

For each cartridge the core test script adds three checks (native ==
sandbox with saves and loads, a state across processes, and the EPSM's own
share of the sound), and one more through chimera-run for them all (a
movie replayed in a new process); the frontend test adds one (each in
Chimera's window). Without the folder they say SKIP.
`docs/PLAN.md` says what each check compares and how each was seen to
fail.

### Chimera's contract tests

```
<chimera>/build/meson-linux/source/ui/test-packages <a folder holding only mesen.chimeraCore>
python3 <chimera>/tools/check-core-texts.py .
```

### The frontend test

```
./waterbox/tests/run-frontend.sh --chimera-root <chimera> [--package <mesen.chimeraCore>] [--qt-lib <Qt's lib folder>]
```

It runs Chimera's window headless (no display) on projects it makes with
`chimera-run --new-project`, and compares the console's RAM with the native
reference's: 8 checks (the NES's 5 and the Super NES's 3), three more with
`MESEN_CONTENT_DIR` (the real rhythm ROM, Sonic, the Disk System), two more
with `MESEN_SYSTEMS_CONTENT` (a Super NES game, the Super Game Boy) and one
with `MESEN_FAMISTUDIO_ROMS`. Its files stay in `waterbox/tests/work/` (ignored by
git). `--qt-lib` is for a window built against a Qt the system does not
know of, such as `~/qt/6.12.0/gcc_64/lib` after `tools/ci-chimera.sh`.

## What CI does

`.github/workflows/chimera.yml` (written, not yet run: the repository has
no remote): one job builds both flavors and runs the core test script; the
other builds Chimera, the package (`-r`), runs the contract tests, the core
test script with `CHIMERA_ROOT`, and the frontend test, and uploads the
package; then Chimera's `publish-core.yml` publishes it.

## Files the user brings

| What | Where | When |
| --- | --- | --- |
| The game (.nes, .unf) | the Cartridge slot | always (the NES) |
| The game (.sfc, .smc, .bs, .st; .gb, .gbc for the Super Game Boy) | the Game slot | always (the other machines) |
| A chip's program (dsp1.rom, dsp1b.rom, dsp2.rom, dsp3.rom, dsp4.rom, st010.rom, st011.rom, st018.rom) | firmware, asked for by the game | a Super NES game with that chip |
| The Super Game Boy's program (SGB1.sfc, 256 KiB) or the Super Game Boy 2's (SGB2.sfc, 512 KiB) | firmware | the Super Game Boy |
| Nintendo's Super Game Boy boot ROM (sgb_boot.bin, sgb2_boot.bin) | firmware | Boot ROM = Nintendo's |
| The Satellaview's BIOS (BS-X.bin) | firmware | a .bs file |
| The Sufami Turbo's BIOS (SufamiTurbo.sfc) | firmware | a .st file |
| A saved game (.sav) | the Saved game slot | to continue one |
| A Famicom Disk System disk (.fds) | the Cartridge slot | always |
| The rhythm ROM (`ym2608_adpcm_rom.bin`, 8 KiB, SHA-1 50b6c3e2...) | firmware `ymf288_adpcm_rom.bin` | an EPSM game with EPSM Drums on |
| The Disk System's BIOS (`disksys.rom`, 8 KiB, SHA-1 57fe1bde...) | firmware `disksys.rom` | a .fds game |

## Troubleshooting

- `pass -Dminibox_dir=<miniBox checkout>`: the native build needs the path.
- `extern/MesenCE is empty`: `git submodule update --init`.
- `extern/MesenCE has changes that are not this repository's patches`: put
  the submodule back to its pin (`git -C extern/MesenCE checkout -- .`).
- `miniBox: the core asked for system call N`: a call Mesen makes that the
  sandbox does not provide. Answer it in `waterbox/guest-syscalls.c` (that
  is how `mkdir` is answered).
- The test scripts compare stale binaries without complaint: rebuild both
  flavors after a change.
- The window fails with `libQt6Core.so.6: cannot open shared object file`:
  pass `--qt-lib`.

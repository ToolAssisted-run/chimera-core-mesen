# Building the Mesen core

This repository builds MesenCE as a sandboxed guest (`core.wbx`) and
packages it as one file, `mesen.chimeraCore`, which Chimera loads as the
NES and as each other system Mesen emulates (the Super NES, the Super Game
Boy, the Game Boy, Game Boy Color and Game Boy Advance, the PC Engine,
SuperGrafx and PC Engine CD, the Master System, Game Gear, SG-1000 and
ColecoVision, the WonderSwan, WonderSwan Color and Pocket Challenge V2),
picked by a project's setting `machine`, with Mesen's other controllers
(the Super NES Mouse and Super Scope, the Light Phaser, the Avenue Pad 6) as
choices of the controller port settings.

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

- Only to build the test programs again (their results are committed in
  `tests/roms`, so the tests do not need these): nasm for the WonderSwan's
  (`tests/ws-test`), and LLVM's `clang`, `ld.lld` and `llvm-objcopy` (version
  20 was used: `clang-20`, `ld.lld-20`, `llvm-objcopy-20`, or set `CLANG`,
  `LLD`, `OBJCOPY`) for the Game Boy Advance's (`tests/gba-test`); the
  others are written by Python scripts.

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
folder). It ends with `<n> ok, <m> failed`; without Chimera it is 287
checks, and SKIP lines for the checks that need Chimera or the owner's
files. The other machines' checks are in `waterbox/tests/systems.sh`, which
it sources. With

```
CHIMERA_ROOT=<chimera> MESEN_PACKAGE=<the package> ./waterbox/run-gate.sh
```

more run: Chimera's own checks of the texts, and the ones through
`<chimera>/build/dll/chimera-run`: 328 checks. With all of the owner's
files (below) and `MESEN_PUBLISHED_PACKAGE`, 406.

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
| `systems/gb/`: Bugs Bunny - Crazy Castle II, A_FAIRY_WITHOUT_WINGS, Kirby's Hoshinoka-Bi; `firmware/GB_dmg.bin` | `gb:game:*` |
| `systems/gbc/`: Super Mario Bros. Deluxe, Pokemon Gold, Prince of Persia, aslimetravel; `firmware/GBC_cgb.bin` | `gbc:game:*`, `gbc:game-frontend` |
| `firmware/GBA_bios.rom` with `systems/gba/`: tollrunner_jam, Another_world, Megaman Battle Network, Rhythm Tengoku, WarioWare Inc., Yu-Gi-Oh! Worldwide Edition | `gba:game:*`, `engine:gba`, `gba:game-frontend` |
| `firmware/GBA_bios.rom` alone | `gba:skip-boot` (the test program with Nintendo's BIOS, boot screen skipped and not) |
| `systems/snes/Arkanoid - Doh It Again (J) [!].smc` | `snes:game:arkanoid-mouse` (the Super NES Mouse in port 2) |
| `systems/sms/`: mai_nurse, Galactic Protector; `systems/gamegear/`: Prince of Persia (a Master System cartridge), Frogger, Nazo Puyo; `firmware/SMS_us_1.3.sms`, `SMS_jp_2.1.sms` | `sms:game:*`, `gg:game:*` |
| `systems/sg1000/`: Pitman, Monaco GP, foryster | `sg1000:game:*` |
| `systems/pcengine/`: Bomberman (U), Bomberman '93 (J), Bomberman '94 (J), 1941 - Counter Attack (SGX) | `pce:game:*`, `sgx:game:1941` |
| `firmware/PCECD_3.0-(J).pce` with `systems/pcEngineCD/`: F1 Team Simulation Project F, Magical Dinosaur Tour (.cue and .img) | `pcecd:game:*`, `pcecd:state-size`, `engine:pcecd`, `pcecd:frontend`; the firmware alone: `pcecd:card-type` |
| `systems/wonderswan/`: Saint Seiya - Ougon Densetsu Hen | `wsc:game:saintseiya`, `wsc:game-frontend` |
| `firmware/Coleco_Bios.bin` with `systems/coleco/`: Carnival, Oil's Well | `coleco:*` (the test program too), `coleco:game:*`, `coleco:power-renamed`, `engine:coleco`, `coleco:frontend`, `coleco:keybinds` |

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
reference's: 45 checks (the NES's 5, each other machine's test program
in the window and its default keys, and the devices beyond the pad, among
them the Super NES Mouse, Super Scope, NTT Data Keypad and BlueRetro
adapter, the Light Phaser, Avenue Pad 6, the NES's devices and the tilt
sensors, with their buttons held and axes set through the window), more with `MESEN_CONTENT_DIR` (the
real rhythm ROM, Sonic, the Disk System) and `MESEN_SYSTEMS_CONTENT` (a
game of each machine whose BIOS or games are the owner's): 56 in all; and
one with `MESEN_FAMISTUDIO_ROMS`. Its files stay in `waterbox/tests/work/` (ignored by
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
| The game (.sfc, .smc, .bs, .st; .gb, .gbc; .gba; .pce, .sgx; .sms, .gg, .sg, .col, .rom, .bin; .ws, .wsc, .pc2) | the Game slot | always (the other machines) |
| A PC Engine CD game's .cue, with the image it names beside it | the Disc slot | the PC Engine CD |
| The Super CD-ROM System card 3.0 (syscard3.pce, 256 KiB) or the Games Express card (gecard.pce) | firmware, asked for by the disc | the PC Engine CD |
| Bandai's WonderSwan boot ROM (bootrom.ws, bootrom.wsc; the SwanCrystal's bootrom_sc.wsc) | firmware | Boot ROM on |
| A chip's program (dsp1.rom, dsp1b.rom, dsp2.rom, dsp3.rom, dsp4.rom, st010.rom, st011.rom, st018.rom) | firmware, asked for by the game | a Super NES game with that chip |
| The Super Game Boy's program (SGB1.sfc, 256 KiB) or the Super Game Boy 2's (SGB2.sfc, 512 KiB) | firmware | the Super Game Boy |
| Nintendo's Super Game Boy boot ROM (sgb_boot.bin, sgb2_boot.bin) | firmware | Boot ROM = Nintendo's |
| Nintendo's Game Boy boot ROM (dmg_boot.bin) or Game Boy Color boot ROM (cgb_boot.bin) | firmware | Boot ROM = Nintendo's |
| The Game Boy Advance's BIOS (gba_bios.bin, 16 KiB) | firmware | the Game Boy Advance, unless its setting BIOS is None (only for programs that call none of it) |
| The Master System's BIOS (bios.sms: the American 1.3 or the Japanese 2.1) | firmware | Master System BIOS on |
| The ColecoVision's BIOS (bios.col, 8 KiB) | firmware | the ColecoVision |
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

## Two CPUs

CI builds and tests the core twice, once for each CPU, on a runner of that
CPU (x86_64 on ubuntu-24.04, aarch64 on ubuntu-24.04-arm): a package is
machine code for one CPU, and the guest is built for the CPU it is built on.
A nightly carries both packages, `<id>-<version>-x86_64.chimeraCore` and
`<id>-<version>-aarch64.chimeraCore`. On aarch64 the linked `core.wbx` goes
through miniBox's `wbx-tp-rewrite.py`, which points its thread-pointer reads
at the machine's slot.

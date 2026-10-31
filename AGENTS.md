# AGENTS.md - Mesen core for Chimera

This repository builds MesenCE (Mesen 2's community edition) as a sandboxed
guest for Chimera and packages it as `mesen.chimeraCore`: `core.wbx` (the
emulator built for miniBox), `waterbox.config`, `file_slots.json`,
`default_keybinds.json`, `languages/`, `pictures/`, the licence texts and
`build.json`. It runs the NES, with the EPSM, and, as machines of the same
package picked by the setting `machine`, the Super NES, the Super Game
Boy, the Game Boy, the Game Boy Color, the Game Boy Advance, the Master
System, the Game Gear, the SG-1000 and the ColecoVision; Mesen's other
systems are being added one by one (owner, 2026-10-31).
`docs/BUILDING.md` has every step; `docs/PLAN.md` the reasons and the state
of the work.

## Layout

- `extern/MesenCE/` - upstream, a submodule pinned to unmodified MesenCE.
- `patches/` - every change to upstream, numbered, each a build option off
  in Mesen's own build (single thread, a random sequence of our own, a hook
  at each read of the controls, bare file names, saved games kept by the
  host, no network code, the Arkanoid knob where the host says, the EPSM
  plugged in by a setting, the cartridges' clocks on the machine's time, a
  file with no folder kept as named). `patches/series-marker` names the
  string the last patch adds.
- `meson.build` - one build, two flavors: native (`run-native`, `run-wbx`)
  and guest (`core.wbx`, through the cross file `waterbox/setup-guest.sh`
  writes).
- `waterbox/mesen.cpp` - the adapter: Mesen's `Emulator` behind the guest
  ABI, one machine per system (the NES's path is kept exactly as it was).
  Compiled into both flavors. `snes-coprocessor.inc` (which chip program a
  Super NES cartridge needs) and `pce-palette.inc` (Mesen's PC Engine
  palette) are included by it.
- `waterbox/run-native.c`, `waterbox/run-wbx.c`, `waterbox/gate-harness.h` -
  the reference driver, the sandbox driver and the loop they share.
- `waterbox/run-gate.sh` - the core test script; the other machines' checks
  are `waterbox/tests/systems.sh` (sourced by it) with
  `waterbox/tests/systems.py` (their schedules, movies and RAM checks).
  `waterbox/tests/` - the frontend test (`run-frontend.sh`) and its helpers.
- `waterbox/waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`, `languages/` - the package's declarations.
- `tests/roms/` - free homebrew, the EPSM test program, the input test
  program and the other machines' test programs; `tests/epsm-test/`,
  `tests/input-test/` and `tests/<system>-test/` build them; `tests/inputs/`
  - input schedules written here.
- `build/` - every output (ignored by git).

## Commands, in order

```
MB=<chimera>/extern/chimera-common-minibox     # built with -Dguest_cpp=true in build/meson-cpp
git submodule update --init
meson setup build/meson-native -Dminibox_dir="$MB" && ninja -C build/meson-native -j4
sh waterbox/setup-guest.sh -m "$MB" && ninja -C build/meson-guest -j4
./waterbox/run-gate.sh                                   # 92 ok, 0 failed, the engine and game checks skipped
./waterbox/build-package.sh -m "$MB" -o build/Cores
<chimera>/build/meson-linux/source/ui/test-packages build/Cores
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh            # 108 ok, 0 failed (173 with every owner's file)
./waterbox/tests/run-frontend.sh --chimera-root <chimera> [--qt-lib <Qt lib folder>]   # 15 ok (24 with the owner's files)
python3 <chimera>/tools/check-core-texts.py .            # every key named
```

`MESEN_CONTENT_DIR=<folder>` holding the owner's NES games and BIOS files
under their own names (`docs/BUILDING.md` lists them) adds the checks on real
games, the real rhythm ROM and the Disk System; `MESEN_SYSTEMS_CONTENT=<folder
with systems/<system>/ and firmware/>` the other machines' games and BIOS
files; `MESEN_PUBLISHED_PACKAGE=<the NES package as published>` the checks
that the NES is still that machine. Without them they say SKIP. Never copy
that content into this repository.

`MESEN_FAMISTUDIO_ROMS=<folder of EPSM songs FamiStudio exported to .nes>`
adds the FamiStudio checks to `run-gate.sh` and `run-frontend.sh`; without
it they say SKIP. Nothing of FamiStudio is in this repository yet.

The test scripts build nothing: rebuild both flavors first, or they compare
stale binaries (it happened here once: the sandbox was one build behind).

## Rules of this repository

- Upstream is never edited in place and never committed inside. A change is
  a new numbered patch, a build option or a hook. After changing
  `patches/`, put the submodule back (`git -C extern/MesenCE checkout -- .`)
  and configure again; `apply-patches.sh` applies all or none.
- Determinism is the product: no host time, no host randomness
  (`std::random_device` is RDRAND), no threads. `run-gate.sh` checks it.
- A new check is broken on purpose once and seen to fail; say so in the
  commit.
- No commercial game, BIOS or firmware in the repository; the real YMF288
  rhythm ROM, the Disk System's BIOS and every other console's BIOS are
  never committed. No BizHawk material of any kind.
- The NES stays the machine it was: a project or movie made before the
  other machines plays the same (`nes:published`, `engine:nes-published`).
- Never add network access. Mesen's netplay and luasocket are left out of the build
  (patch 0006); `build:no-network` in `run-gate.sh` checks `core.wbx`.
- Do not write `version` or `versionDate` into `waterbox.config`.
- Every text a person reads is a key of `waterbox/languages/en.json`, and
  every language file has every key.
- Commits: `type(mesen): what changed`, a plain-language body with what ran
  and the numbers, and the trailers the Chimera project uses.
- Prose in `.md` files is ASCII.

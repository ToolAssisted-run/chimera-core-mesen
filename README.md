# chimera-core-mesen

**Mesen as a Chimera core.** [MesenCE](https://github.com/nesdev-org/MesenCE),
the community edition of Mesen 2, built into
[miniBox](https://github.com/ToolAssisted-run/chimera-common-minibox)'s
sandbox and packaged for [Chimera](https://github.com/ToolAssisted-run/chimera),
a frontend for tool-assisted speedruns. It runs NES games, with Mesen's
accuracy and the **EPSM** sound expansion (a Yamaha YMF288 on the Famicom's
expansion port) that some new NES games use. The controller ports hold a
pad, the Four Score (four players), the Zapper or the Arkanoid controller;
the Famicom's expansion port holds its own Zapper, its Arkanoid controller
or the four-player adapter.

Mesen's other systems (SNES, Game Boy, GBA, PC Engine, Master System,
WonderSwan) are compiled in but not offered yet; `docs/PLAN.md` says what
each would take.

## Using it in Chimera

Chimera ships no cores and downloads none. Build the package (below), or
take it from this repository's releases once there are some, and put
`mesen.chimeraCore` in Chimera's cores folder. Game files are not included.

An EPSM game says so in its NES 2.0 header, and Mesen then plugs the EPSM
in. Its music and sound effects play with nothing more. Its drums play
samples from the chip's own ROM: turn on the setting **EPSM Drums** (the
new-project window suggests it for an EPSM game) and give Chimera the
8 KiB file `ymf288_adpcm_rom.bin` (the same data as MAME's
`ym2608_adpcm_rom.bin`).

## Build and test

`<chimera>` is a built Chimera checkout and `<minibox>` its
`extern/chimera-common-minibox`, built with the C++ guest toolchain.

```
git submodule update --init
meson setup build/meson-native -Dminibox_dir=<minibox> && ninja -C build/meson-native
sh waterbox/setup-guest.sh -m <minibox> && ninja -C build/meson-guest
./waterbox/run-gate.sh                                  # native == sandbox, savestates, EPSM, settings
./waterbox/build-package.sh -m <minibox> -o build/Cores  # the package
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh           # adds the checks through chimera-run
./waterbox/tests/run-frontend.sh --chimera-root <chimera> # the package in Chimera's window
```

Every step is in [docs/BUILDING.md](docs/BUILDING.md); the design log is
[docs/PLAN.md](docs/PLAN.md); an AI agent starts at [AGENTS.md](AGENTS.md).

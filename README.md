# chimera-core-mesen

**Mesen as a Chimera core.** [MesenCE](https://github.com/nesdev-org/MesenCE),
the community edition of Mesen 2, built into
[miniBox](https://github.com/ToolAssisted-run/chimera-common-minibox)'s
sandbox and packaged for [Chimera](https://github.com/ToolAssisted-run/chimera),
a frontend for tool-assisted speedruns. It runs NES and Famicom Disk System
games, with Mesen's accuracy and the **EPSM** sound expansion (a Yamaha YMF288 on the Famicom's
expansion port) that some new NES games use. The controller ports hold a
pad, the Four Score (four players), the Zapper or the Arkanoid controller;
the Famicom's expansion port holds its own Zapper, its Arkanoid controller
or the four-player adapter.

Every other system Mesen emulates is offered by the same package (the
owner's decision, `docs/PLAN.md`): a project's **Console** setting picks
it. The **Super NES / Super Famicom** (two controllers, or a multitap for
five players; the programs of the cartridge chips DSP-1 to 4, ST010, ST011
and ST018 are asked for as the game's firmware), the **Super Game Boy**,
the **Game Boy**, **Game Boy Color** and **Game Boy Advance** (with its
BIOS), the **PC Engine / TurboGrafx-16**, **SuperGrafx** and **PC Engine
CD** (a .cue and its image, with the System Card), the **Master System**,
**Game Gear**, **SG-1000** and **ColecoVision** (with its BIOS), and the
**WonderSwan** and **WonderSwan Color**. The Satellaview (.bs) and the
Sufami Turbo (.st) are declared but not tried: no BIOS for them was at
hand. An NES project made before keeps playing as it did.

## Using it in Chimera

Chimera ships no cores and downloads none. Build the package (below), or
take it from this repository's releases, and put
`mesen.chimeraCore` in Chimera's cores folder. Game files are not included.

An EPSM game says so in its NES 2.0 header, and Mesen then plugs the EPSM
in. For a file with a plain iNES header, choose **EPSM** under **Expansion
Port** (the new-project window suggests it when the game's program writes
the EPSM's registers). The drums play samples from the chip's own ROM: turn
on **EPSM Drums** and give Chimera the 8 KiB rhythm ROM
(`ym2608_adpcm_rom.bin`, SHA-1 `50b6c3e2...`).

Famicom Disk System games (.fds, all sides in one file) need the Disk
System's BIOS (`disksys.rom`, SHA-1 `57fe1bde...`). The first side is in the
drive at power on; **Eject Disk** takes the disk out while held, **Previous
Disk** and **Next Disk** choose the side that goes back in.

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

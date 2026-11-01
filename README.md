# chimera-core-mesen

**Mesen as a Chimera core.** [MesenCE](https://github.com/nesdev-org/MesenCE),
the community edition of Mesen 2, built into
[miniBox](https://github.com/ToolAssisted-run/chimera-common-minibox)'s
sandbox and packaged for [Chimera](https://github.com/ToolAssisted-run/chimera),
a frontend for tool-assisted speedruns. It runs NES and Famicom Disk System
games, with Mesen's accuracy and the **EPSM** sound expansion (a Yamaha YMF288 on the Famicom's
expansion port) that some new NES games use. The controller ports hold a
pad, the Four Score (four players), the Zapper, the Arkanoid controller or
the Power Pad;
the Famicom's expansion port holds its own Zapper, its Arkanoid controller,
the four-player adapter, the Family Trainer mat, Konami's Hyper Shot or
the Party Tap.

Every other system Mesen emulates is offered by the same package (the
owner's decision, `docs/PLAN.md`): a project's **Console** setting picks
it. The **Super NES / Super Famicom** (two controllers, or a multitap for
five players; the programs of the cartridge chips DSP-1 to 4, ST010, ST011
and ST018 are asked for as the game's firmware), the **Super Game Boy**,
the **Game Boy**, **Game Boy Color** and **Game Boy Advance** (with its
BIOS), the **PC Engine / TurboGrafx-16**, **SuperGrafx** and **PC Engine
CD** (a .cue and its image, with the System Card), the **Master System**,
**Game Gear**, **SG-1000** and **ColecoVision** (with its BIOS), and the
**WonderSwan**, **WonderSwan Color** (or SwanCrystal) and **Pocket Challenge
V2**. The Satellaview (.bs) and the Sufami Turbo (.st) are declared but not
tried: no BIOS for them was at hand. An NES project made before keeps
playing as it did.

A cartridge's clock (Game Boy Advance, WonderSwan, Game Boy MBC3, the
Super NES's SPC7110) starts at the project's **Clock Start** and moves with
the game's own time, never the computer's.

Mesen's other controllers are offered too: the **Super NES Mouse** and the
**Super Scope**, the Master System's **Light Phaser** and the PC Engine's
six-button **Avenue Pad 6**, each a choice of a port setting; the mice and
light guns follow your mouse. Every other device Mesen emulates for the NES is offered too: a Super NES
controller, Super NES Mouse or NTT Data Keypad in an NES port, the Subor
mouse, the Virtual Boy controller, the Famicom's second controller (with
its microphone), and on the expansion port the two-player adapter, the
Oeka Kids tablet, the **Family BASIC keyboard** (72 keys) and the **Subor
keyboard** (99 keys), the Pachinko and Famicom Network System
controllers, the Exciting Boxing bag, the Jissen Mahjong controller, the
Hori Track and Bandai's Hyper Shot; Karaoke Studio's microphone; and the
console model (NES, NES top-loader, Famicom, AV Famicom). The keyboards'
keys are on the PC keyboard's keys. A **Game Boy Advance** game can
skip the console's boot screen (**Skip Boot Screen**, off by default as in
Mesen); a game still needs the BIOS, which only programs made to call none
of it can do without (**BIOS: None**).

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

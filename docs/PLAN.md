# chimera-core-mesen: Mesen as a Chimera core

This is the design log of the Mesen core: what was decided, why, and what
was measured. Entries are dated. The last section, "Where this stands", is
kept current for whoever continues the work.

The request is chimera issue #410: Mesen 2 or its community edition MesenCE,
for the NES with the EPSM sound expansion.

## 2026-10-31: feasibility

### Which Mesen

There are two repositories:

- https://github.com/SourMesen/Mesen2 - the original. Its README now says it
  is "an archive of Mesen as it was around version 2.1.1 in mid-2025" and
  sends people to the community edition. Last commit b9fa69dd (2026-06-04),
  a README change.
- https://github.com/nesdev-org/MesenCE - the community edition, the same
  code carried on by the NESdev community (Sour, the original author, still
  commits there). 3809 commits against Mesen2's 3511.

Both have the EPSM. MesenCE has two EPSM fixes Mesen2 does not:
963f9f2e "Fixes EPSM so that it works correctly after reset" and 41c27b82
"NES: EPSM: ymfm fixes (#292)" (2026-10-07, a sync of the YM chip library
with its upstream). The core pins **MesenCE at 4b8a196e** (2026-10-07), the
head of its default branch when the work started. It is where Mesen is
maintained now and it has the better EPSM. (Which fork is the owner's to
confirm; see "Questions for the owner".)

### What the EPSM is in Mesen, and how complete

The EPSM ("Expansion Port Sound Module") is a Yamaha YMF288 (OPN3-L, the
YM2608's cut-down sister) on the Famicom expansion port. In MesenCE:

- `Core/NES/Epsm.{h,cpp}` and `Core/NES/OpnInterface.h` wrap the YMF288 of
  ymfm (Aaron Giles' Yamaha FM library, BSD-3, in `Utilities/Audio/ymfm`),
  clocked at 8 MHz from the NES master clock and resampled into Mesen's
  mixer.
- All three parts of the chip are there: 6 FM channels, the 3-channel SSG,
  and the 6-instrument rhythm part (ADPCM-A). The YMF288 has no ADPCM-B, so
  nothing is missing there.
- Both ways a game writes the chip work: the registers at $401C-$401F, and
  the $4016 "OUT1" interface (two writes per register, data on the bus).
  The chip's timers raise the CPU's IRQ. Reads of the chip return 0: there
  is no status read, as on the cartridge.
- The EPSM is plugged in by the cartridge's header only: an NES 2.0 header
  with console type 3 and extended console type 4. Mesen has no setting to
  force it.
- The rhythm part plays samples from the chip's own 8 KiB ROM, which Mesen
  reads from the firmware file `ymf288_adpcm_rom.bin`. It is Yamaha's data
  and the user brings it. Without it Mesen plays zeros there: FM and SSG
  sound, the drums are silent.
- The volume is a Mesen setting (`EpsmVolume`, 0-100).

### What this core adds to Chimera

Chimera already runs the NES in quickerNES, Mednafen and ares. Mesen adds:

- the EPSM, which none of them has;
- Mesen's accuracy: a cycle-accurate CPU, PPU and APU tested against the
  community's test ROMs, more than 300 mappers, every Famicom expansion
  audio chip (VRC6, VRC7, MMC5, Namco 163, Sunsoft 5B, FDS), and the
  NES 2.0 game database Mesen's UI ships (10655 games), compiled in;
- later, Mesen's other systems (below).

### The questions of docs/new-core.md, section 1

- **Licence.** GPL-3.0 at the pinned commit (`LICENSE`). Modification and
  binary redistribution are allowed with the source. The libraries inside
  are GPL-compatible: ymfm (BSD-3), miniz (public domain), spng (BSD-2 and
  libpng), kissfft (BSD-3), magic_enum (MIT), Lua 5.4 (MIT) with
  luasocket (MIT), the 7-Zip LZMA SDK (public domain), xBRZ and Scale2x
  (GPL), HQX, blip_buf and nes_ntsc (LGPL), stb_vorbis and gif.h (public
  domain).
- **One thread on one clock.** Mesen runs the machine on an emulation
  thread of its own, decodes pictures on a second and renders on a third,
  and paces frames with a frame limiter that sleeps. Patch 0001 makes all of
  that a build option: one frame on the caller's thread, no limiter. The
  NES has no calendar clock; nothing in the machine reads the host's time.
  Mesen has its own savestates, movies, rewind and netplay, which is the
  best sign there is that the machine is deterministic.
- **Randomness.** Mesen draws power-on values (RAM, CPU/PPU alignment when
  asked) from `std::random_device`, which on x86 is the RDRAND instruction.
  Patch 0002 gives it a sequence of its own (splitmix64, its state a plain
  global in the guest's memory) seeded from a setting, `randomSeed`.
- **The picture.** The machine's own framebuffer: the PPU's output, turned
  into colours by Mesen's default video filter with the palette Mesen's UI
  uses by default. No GPU.
- **Recompiler.** None.
- **What the user brings.** The game. For an EPSM game's drums,
  `ymf288_adpcm_rom.bin` (8 KiB). For the Famicom Disk System, its BIOS
  (not offered yet).
- **What CI can run.** Everything, on free content: the homebrew games
  Nova the Squirrel and Sprilo (the same files the quickerNES core's
  repository carries), and an EPSM test program written for this repository
  (`tests/epsm-test/make-epsm-test.py`). Only the EPSM drums with the real
  rhythm ROM need a file CI cannot have; their leg uses a made-up ROM to
  prove the file reaches the chip.
- **Memory.** The whole of Mesen's library is about 13 MB of guest code.
  An NES game needs little memory; the layout is 64 MiB sbrk, 4 sealed,
  4 invisible, 4 plain, 64 mmap. A savestate of Nova is 1.4 MB.

### Mesen's other systems

The core compiles the whole of Mesen's library, so the SNES, Game Boy and
Game Boy Color, Game Boy Advance, PC Engine (and CD), Master System, Game
Gear and WonderSwan are already inside `core.wbx`; loading one of their
games is refused today with "not an NES game". Each would need, as a
machine of this package (the ares core's shape): its controller
declaration, its memory domains, its settings, and its firmware - the GBA
BIOS (required), the SNES coprocessor programs (DSP-1 to 4, ST010/11, the
Super Game Boy), the PC Engine CD system card, the optional Game Boy and
WonderSwan boot ROMs. The engine side (one thread, the random sequence) is
shared and done. Each system is a few days of declarations and tests; the
SNES and the GBA would be the ones worth doing first, for Mesen's accuracy.

## 2026-10-31: the build

- `extern/MesenCE`, pinned at 4b8a196e, never edited in place.
- `patches/`, applied all or none by `waterbox/apply-patches.sh` (meson runs
  it at every configure). Each is a build option, off in Mesen's own build:
  - 0001 `MESEN_SINGLE_THREAD`: `Emulator::RunSingleFrame()`, no emulation,
    decode or render thread, no frame limiter, and
    `VideoDecoder::SetDecodeEnabled` for turbo;
  - 0002 `MESEN_FIXED_RANDOM`: `MESEN_RANDOM_DEVICE` in place of
    `std::random_device` at its six uses;
  - 0003 `MESEN_INPUT_READ_HOOK`: a function called at each read of
    $4016/$4017, for Chimera's input-poll callback (chimera#344).
- `meson.build` builds both flavors from the same sources:
  `waterbox/list-sources.py` lists Mesen's Core, Utilities, SevenZip and Lua
  (434 files, Mesen's own makefile's set less the frontends), and
  `waterbox/embed-db.py` compiles the game database in.
- `waterbox/mesen.cpp` is the adapter. It makes one `Emulator`, sets it up
  the way Mesen's UI does by default (the UI passes its settings in, and
  some of the core's own defaults are not the UI's: every channel volume
  is 0 and the palette is empty in the core), and hands it three devices:
  an input provider, a sound device that keeps the frame's samples (48000 Hz
  stereo) and a rendering device that keeps the frame's picture.
- `waterbox/guest-syscalls.c`: `mkdir` answers "read-only" (Mesen makes sure
  its folders exist whenever it asks for one).

Traps met:

- **Mesen's settings reset the firmware folder.** `EmuSettings::SetPreferences`
  calls `FolderUtilities::SetFolderOverrides(..., "")`: the firmware override
  is set to nothing every time preferences are set. The adapter sets the
  folders after it sets the preferences; before that, Mesen looked in
  `./Firmware/` and the rhythm ROM was never found.
- **An input provider belongs to the console, not the emulator.**
  `Emulator::RegisterInputProvider` passes it to the console that exists at
  that moment. Registered before the game is loaded it goes nowhere, and a
  power cycle makes a new console. The adapter registers it after the load
  and after every power cycle.
- **The core's defaults are not the UI's.** All NES channel volumes default
  to 0 in `SettingTypes.h` (the UI sets 100), and `UserPalette` is all zeros.

Measured (native reference, this machine):

- Nova the Squirrel, 600 frames of the pad exercise: 0.7 s natively; native
  and sandbox agree on every digest; the sandbox with a save and a load
  around every frame agrees too (1.0 s); a state saved at frame 300 and
  loaded by another process ends on the same machine at frame 600.
- Nova with this repository's schedule (`tests/inputs/nova.inputs`, 3000
  frames: Start through the title, A through the story, then running right)
  reaches the first level.
- The EPSM test program: with the EPSM header the sound has an RMS of about
  4450 (FM and SSG playing); the same program with a plain header is silent.
  A made-up 8 KiB rhythm ROM changes the sound (RMS about 3400), which shows
  the firmware file reaches the chip.

## 2026-10-31: the core test script

`waterbox/run-gate.sh` compares the sandboxed core with the native reference
and needs no Chimera. 23 checks pass, 1 is skipped (the one through
Chimera's engine, which needs a built Chimera and the package):

- `<game>:equivalence`, `:input-shaped`, `:savestate`, `:turbo` for Nova
  (3000 frames of `tests/inputs/nova.inputs`), Sprilo (1200 frames of the
  pad exercise) and the EPSM test program (600): native == sandbox on
  frames, picture, sound, lag and every memory domain; an idle run is
  another machine; a save and a load around every frame change nothing; with
  no picture for half the run, everything but the undrawn pictures is the
  same.
- `nova:session`: a state saved at frame 1500 by one process and loaded by
  another ends on the straight run's machine; the same state loaded as if
  taken ten frames earlier does not (the check can fail).
- `time:stall`: a 300 ms stop of the host changes nothing, native and
  sandboxed.
- `epsm:present`: the EPSM header plugs the chip in (Mesen's log line, both
  flavors); with it the sound has an RMS of 4300, without it the program is
  silent; the RAM is the same either way.
- `epsm:firmware`: a made-up 8 KiB rhythm ROM changes the sound in both
  flavors alike; a 4 KiB file is refused as Mesen refuses it.
- `settings:*`: `port1`, `region`, `ramPowerOnState` and `randomSeed` each
  build another machine than their baseline, native == sandbox; PAL runs at
  322445/6448 frames a second.
- `savedata:export`: Nova's 32 KiB battery RAM comes out the same.

Each check was seen to fail (gates.md, B), with the build broken on purpose
and then put back:

- a sandbox left one build behind (the input fix built natively only):
  every equivalence check failed;
- `SetRenderingEnabled` a no-op: the three turbo checks failed ("drew every
  frame");
- the EPSM's volume 0: `epsm:present` and `epsm:firmware` failed;
- `port1` read as "gamepad" whatever it said: `settings:port1` failed;
- no save data offered: `savedata:export` failed;
- a host clock read written into RAM each frame: `time:stall` failed on the
  native run (and every equivalence check);
- `run-wbx --rerecord` loading the first frame's state each frame: the three
  savestate checks failed.
- `epsm:firmware` failed for real before patch 0004: the sandbox looked for
  `./ymf288_adpcm_rom.bin`, which no mount is called, while the native run
  found it in its working folder. Patch 0004 (`MESEN_BARE_PATHS`) names a
  file in the folder "." by its bare name.

## 2026-10-31: the package

`waterbox/build-package.sh -m <miniBox> -o <folder>` writes
`mesen.chimeraCore` (`-r <chimera>` writes it into a Chimera checkout's
build/Cores, which is what Chimera's publishing job runs). What it declares:

- the system `NES`, named "Nintendo Entertainment System"; 512x240 room
  for the picture (256x240, or 512x240 for a VS DualSystem game showing
  both screens), shown at 293x240; 48000 Hz stereo sound; NTSC's
  39375000/655171 frames a second, PAL and Dendy 322445/6448 (the same
  rates Mesen uses: 60.0988 and 50.0070);
- the controller: Power and Reset (the console's), then pads 1 and 2 in
  quickerNES's order, the same letters as quickerNES's movies (A B s S U D
  L R), and P and r for Power and Reset. The picture is the quickerNES
  core's photograph of an NES pad (public domain). Default keys bind pad 1
  only and leave Power and Reset unbound;
- settings: `region` (auto, ntsc, pal, dendy), `port1` and `port2`
  (controller or nothing), `ramPowerOnState` (zeros - Mesen's own default
  - ones, random), `randomSeed`, and `epsmDrums` (off, on);
- one firmware: `ymf288_adpcm_rom.bin`, 8 KiB, needed when `epsmDrums` is
  on. No SHA-1 is pinned (nobody here has seen the file; it can be pinned
  when the owner provides it). Its name hints are adpcm, 2608, 288, rhythm;
- `SuggestSettings` reads the cartridge's header and suggests `epsmDrums`
  on for an EPSM cartridge. The drums are a setting and not a firmware
  every EPSM game must bring, because they change the sound only (the
  rhythm part's samples are never read back by the machine), so a person
  without the ROM can still play and make movies;
- two file slots: the cartridge (.nes, .unf, .unif) and the saved game it
  starts from (.sav). The saved game is kept in the guest's memory (patch
  0005, `MESEN_BATTERY_SINK`): what the game saves replaces it, and a power
  cycle reloads it, as on the console. `Emulator > Export Save Data`
  writes the battery RAM as battery.sav;
- the texts, in all 26 of Chimera's languages (37 keys; the 25 others
  translated by Claude, like every core's).

Measured: Chimera's contract tests (`test-packages`) pass, 21 checks;
`tools/check-core-texts.py`: 37 keys, every one named, every name a key.
`run-gate.sh` with `CHIMERA_ROOT` and the package adds three checks through
chimera-run - 2376 reads of the pads in 300 frames of Sprilo reach Chimera's
input-poll callback; the suggestion is made for the EPSM cartridge and not
for Nova; the rhythm ROM given to Chimera reaches Mesen - and three for the
saved game (imported, refused by a cartridge with no battery, kept across a
power cycle). 29 ok, 0 failed. Seen to fail: the input-read hook not set
(`inputPolls=0`), and the battery sink not set (the power cycle lost the
saved game).

Trap: Nova writes into its battery RAM from the fourth frame after power
on, so "the battery RAM survived a power cycle" is checked two frames after
Power, against the same schedule without Power.

## 2026-10-31: through Chimera

- `waterbox/tests/run-frontend.sh` runs the package in Chimera's Qt window,
  headless, on projects made with `chimera-run --new-project`: Nova's RAM
  after 300 frames is the native reference's; P1 Right+Start held through
  the window (a Lua script, with TAStudio recording) is the native run of
  an input file holding them, and not the idle machine; `port1` none in the
  project makes the held buttons dead; the EPSM test cartridge with the
  drums on and a made-up rhythm ROM chosen in the window boots with the
  EPSM and the ROM, RAM == native; the package's default keys are the
  machine's. 5 ok, 0 failed, in 11 s. Without the firmware chosen the
  window refuses the EPSM project ("this firmware was not found").
- `run-gate.sh`'s `engine:movie`: Nova's 3000-frame schedule written as a
  Chimera movie and played by chimera-run in a project ends on the native
  reference's RAM. Seen to fail: the same movie with each pad's letters in
  the wrong order ends elsewhere.
- Speed: 3000 frames of Nova take 3.9 s in the sandbox (3.8 s natively),
  about 770 frames a second; the EPSM test program about 600 (ymfm runs at
  the chip's 8 MHz).

## 2026-10-31: the system bus

The core exports one bus, "System Bus": the CPU's 64 KiB as the CPU sees
it, read with Mesen's debugger accessor (`NesMemoryManager::DebugRead`,
each handler's `PeekRam`) and written with `DebugWrite` (RAM and the
cartridge's memory only, never a register). `ReadBus` fills up to 64 KiB at
once into memory no savestate carries. Checked: `bus:look` reads the whole
bus after each of Nova's 3000 frames and the machine is the one of the run
without the reads, the bus is the same in both flavors and its first 2 KiB
is the RAM domain; `engine:movie` reads $0000-$07FF through chimera-run and
it is the RAM. Seen to fail: `ReadBus` with Mesen's ordinary `Read` (which
has side effects: reading $2002 clears the vertical blank) changed the
picture, the lag count and the memory.

## Where this stands (2026-10-31)

Works, and is tested here on Linux:

- Mesen's NES in the sandbox, identical to the native reference on two
  homebrew games and the EPSM test program; savestates within a process and
  across processes; turbo; virtual time; the EPSM present or absent by the
  header; the rhythm ROM reaching the chip; settings; saved games in and
  out and across a power cycle; the system bus; the package, its contract tests, its texts
  in 26 languages; chimera-run (input polls, suggestions, firmware, a
  movie); Chimera's window (5 checks).
- Commands and counts: `run-gate.sh` 27 ok (31 with `CHIMERA_ROOT`),
  `run-frontend.sh` 5 ok, `test-packages` 21 PASS, `check-core-texts.py`
  37 keys.

Not done, or not proved:

- **No real EPSM game has been run.** The EPSM is proved on this
  repository's own test program (FM, SSG and rhythm writes through
  $401C-$401F). The $4016 way of writing the chip, the chip's IRQ timers,
  and a real game's music are untried. Needed from the owner: an EPSM game
  or demo that may be used for testing, and the real
  `ymf288_adpcm_rom.bin` (its SHA-1 can then be pinned in
  `waterbox.config`).
- **No commercial game has been tried.** Mesen's accuracy claims are
  Mesen's; this core has run Nova the Squirrel to its first level and
  Sprilo, nothing else.
- **Windows** has not been run (no Windows box in this round). The guest is
  the same file; what has failed only on Windows before is stacks. A
  Windows run should open an EPSM project and Nova in the window, play a
  movie recorded on Linux and end on the same RAM, and save and load a
  state.
- Mesen's other systems are compiled in and refused at load.
- Devices: only the standard pad on ports 1 and 2. The Zapper, Four Score,
  Arkanoid paddle, Famicom expansion devices and the Famicom Disk System
  (which needs its BIOS) are not offered.
- The PPU's bus is not exported (the CPU's is; the PPU's memory is in the
  domains CIRAM, PALRAM, OAM, CHR RAM/ROM).
- CI is written and has never run (no remote).
- Upstream's own test ROM suite (Mesen's `.mtp` recorded tests) is not run:
  the test ROMs are not in the MesenCE repository.

Next, in order: the owner's answers below; an EPSM game from the owner;
the Windows run; the Zapper and Four Score; then the other
systems, the SNES and the GBA first.

Traps, for whoever continues (each one cost time here):

- Build both flavors before a test script: they build nothing and compare
  stale binaries.
- Mesen's `SetPreferences` resets the firmware folder override; set the
  folders after the preferences.
- An input provider registered before the game loads goes nowhere, and a
  power cycle makes a new console: register after both.
- The core's NES config defaults are not the UI's (volumes 0, no palette).
- A path "./name" is not a mount's name: patch 0004.
- Nova writes into its battery RAM from the fourth frame after power on.
- The window needs Qt's libraries: `--qt-lib`.

## Questions for the owner

- Which fork: MesenCE (recommended, chosen) or the archived Mesen2.
- This repository's own licence: GPL-3.0, Mesen's own, because the adapter
  carries Mesen's default palette table and the patches are Mesen's code.
  Other cores' adapters are MIT; this one cannot be.
- Mesen's library contains netplay (`Core/Netplay`) and luasocket in its Lua.
  Both are compiled in and never called; the sandbox has no network calls
  to give them. Patching them out is possible (a build option each).

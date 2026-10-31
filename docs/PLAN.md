# chimera-core-mesen: Mesen as a Chimera core

This is the design log of the Mesen core: what was decided, why, and what
was measured. Entries are dated. The last section, "Where this stands", is
kept current for whoever continues the work; the "Where it stood" sections
before it are what an earlier round left.

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
maintained now and it has the better EPSM. (The owner confirmed this fork
on 2026-10-31; see "the owner's decisions" below.)

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

## 2026-10-31: more of the EPSM in the test program

The test program now also writes SSG channel B through $4016 (OUT1's rising
edge latches the high nibble and the port, its falling edge the low nibble
and writes), and starts the chip's timer A with its IRQ; the IRQ handler
counts in RAM $02 and acknowledges the timer. A third file,
`epsm-no4016.nes`, is the same program with OUT1 held low, so its $4016
writes never reach the chip. The APU's frame IRQ and the DMC's are turned
off, so the only IRQ is the chip's (with the frame IRQ left on, the first
version spent its time in an unacknowledged IRQ: every variant counted 238
"IRQs", the EPSM-less one too).

- `epsm:present` now also requires the timer's IRQs: 56 in 600 frames with
  the EPSM, 0 without.
- `epsm:4016`: channel B through $4016 changes the sound and not the
  machine; with OUT1 low it is silent.

## 2026-10-31: the owner's decisions (user-decided, 2026-10-31)

The owner accepted every recommendation of the first round:

- **Fork**: MesenCE at 4b8a196e, kept.
- **This repository's licence**: GPL-3.0 for all of it, kept. (The adapter
  carries Mesen's default palette table and the patches are Mesen's code,
  so it cannot be MIT as other cores' adapters are.)
- **The EPSM drums**: the setting "EPSM Drums", off by default, suggested
  on for an EPSM cartridge, which makes the rhythm ROM required firmware.
  Kept as built.
- **Network code**: Mesen's netplay and luasocket are patched out with a
  build option before publishing. Done this round (next section).
- **Publishing**: later, as id `mesen` named "Mesen", after a real EPSM
  game has run, with the real rhythm ROM, and after a Windows run.
- **Systems**: the NES only until the EPSM is proved on a real game; then
  the SNES and the GBA.

A rule for the language tables came with them (owner, 2026-10-31): proper
nouns are never translated or bent. Mesen, NES, EPSM, YMF288 and every
other name stay as they are written; a language that puts endings on names
says the sentence with a common noun beside the name. See "names in the
language tables" below.

## 2026-10-31: no network code (patch 0006)

Mesen's library holds netplay (`Core/Netplay`, a game server and client over
`Utilities/Socket`) and luasocket, a socket library for Lua scripts. Before
this round both were compiled into `core.wbx` and never called; the
sandbox has no network calls to give them. They are now out:

- patch 0006, build option `MESEN_NO_NETWORK`: the `Emulator` makes no game
  server or client; the three places that asked "is a netplay client
  connected" take "no"; loading a state no longer asks; the Lua scripting
  context never offers `socket.core` or `mime.core`;
- `waterbox/list-sources.py` leaves out `Core/Netplay`,
  `Utilities/Socket.cpp` and luasocket's 19 files in `Lua/` (434 files
  became 409).

Measured: before, `core.wbx` held the C library's `socket`, `connect`,
`bind`, `listen`, `accept`, `send`, `recv`, `getaddrinfo` and more, and
`GameServer`, `GameClient`, `luaopen_socket_core`; after, none of them.
(`poll` is still linked: the C library uses it for files at start-up; it is
not a network call.) A new check, `build:no-network`
(`waterbox/tests/check-no-network.sh`, run by `run-gate.sh`), looks for
those symbols. Seen to fail on the previous build's `core.wbx` (taken out of
the old package): it named 23 socket functions and the netplay and luasocket
symbols. Every other check passes unchanged: `run-gate.sh` 33 ok with
`CHIMERA_ROOT`, `run-frontend.sh` 5 ok, `test-packages` 21 PASS.

## 2026-10-31: names in the language tables

The owner's rule (2026-10-31): proper nouns are never translated or bent.
Chimera's own checker (`tools/check-proper-nouns.py`) knows only Chimera's
names, and found nothing here. This core's names were bent in 9 of the 25
translated tables, 33 times:

- a genitive or case ending glued on: "Mesens" (Danish, German, Norwegian,
  Swedish), "Mesenin" (Finnish), "Mesennek" (Hungarian), "Mesenu" (Czech),
  "Mesena" (Polish);
- an ending after a sign: "YMF288:n", "EPSM:n" (Finnish), "YMF288:s",
  "EPSM:s" (Swedish), "YMF288's", "EPSM's" (Danish), "Mesen'in", "EPSM'yi"
  (Turkish), "EPSM-et" (Hungarian).

Each sentence now puts a common noun beside the name, by hand: "databazi
her emulatoru Mesen", "Mesen-emulaattorin", "YMF288-piirin", "rytm-ROM fran
YMF288", "Mesen emulatornak", "Mesen emulatorunun", "EPSM cipini" (accents
left out here, as this file is ASCII). A
compound joined by a hyphen ("NES-Spiel", "EPSM-rummut") leaves the name
whole and stays.

`waterbox/tests/check-names.py` checks it, as `texts:names` in
`run-gate.sh`: every name the English text holds must be in each
translation as itself, and no name may have letters glued to it, directly,
after an apostrophe or a colon, or as a short lower-case ending after a
hyphen. Its names are this core's (Mesen, MesenCE, NES, iNES, NES 2.0,
UNIF, Famicom, Nintendo, EPSM, YMF288, YM2608, Yamaha, Dendy, NTSC, PAL,
Zapper, Four Score, Arkanoid, Vaus, Taito, and the package's coreName) and
Chimera's. File names (`ym2608_adpcm_rom.bin`) are not names in a sentence.
It was run with one bent text left (Swedish `suggest.epsm`, "YMF288:s") and
`run-gate.sh` failed on it (34 ok, 1 failed); with that text fixed it passes.
`texts:chimera` runs Chimera's `check-core-texts.py` and
`check-proper-nouns.py` too when `CHIMERA_ROOT` is given.

## 2026-10-31: the Four Score, the Zapper and the Arkanoid controller

The ports now hold more than a pad (settings `port1` and `port2`):

- `port1`: Controller, Nothing, or the **Four Score**, which takes both
  ports and holds four pads (players 3 and 4 are read after 1 and 2, then a
  signature, as on the adapter);
- `port2`: Nothing, Controller, the **Zapper** (light gun), or the
  **Arkanoid controller** (a knob and one button).

The controller declaration is the union of all of them, in a wire order that
only grows (old movies keep their columns): Power, Reset, pads 1 to 4, then
P2 Trigger (the Zapper's, letter T) and P2 Fire (the knob's button, letter
F); axes P2 Zapper X and Y (0 to 65535 across the picture, the spelling new
work uses for a place on the screen, turned into Mesen's pixels in the
core) and P2 Paddle (the knob, 0 to 160 as in the quickerNES core). The core
now exports `IsButtonActive` and `IsAxisActive`, so a machine shows and
records only the controls its ports hold; with the defaults (a pad in port
1, nothing in port 2) a movie has the console's group and player 1's.

- The Four Score's four pads are set through Mesen's controller hub
  (`IControllerHub`), each sub-port a player.
- The Zapper is given its coordinates and trigger each frame; Mesen decides
  whether it sees light from the picture the PPU has drawn so far, as on the
  console (light detection radius 0, Mesen's own default).
- The Arkanoid controller: Mesen moves its knob by the mouse's movement, so
  its position would depend on every frame before. Patch 0007
  (`MESEN_ABSOLUTE_PADDLE`) makes the position the frame's own input: the
  host sets it, and the controller reads it at each strobe.
- Default keys: the mouse's place is where the Zapper points and where the
  knob is, its left button the trigger and the knob's button.
- The Famicom's expansion port (its Zapper, Arkanoid controller, four-player
  adapters and keyboards) and the Famicom Disk System are not offered.

The test cartridge, `tests/input-test/make-input-test.py`
(`tests/roms/input-test.nes`, our own program): it draws the right half of
the screen white and the left half black, keeps 24 raw reads of each port
from every frame in RAM, and counts how many reads of $4017 it takes before
the Zapper sees light. Checks in `run-gate.sh`:

- `dev:fourScore`, `dev:zapper`, `dev:arkanoid`: a 240-frame schedule that
  moves every control of the device gives the same machine natively,
  sandboxed, and sandboxed with a save and a load around every frame; the
  RAM shows the last frame's controls (the four pads and both signatures;
  the trigger; the knob, 0x54 plus the paddle's value, and its button); and
  with a plain pad in the ports the cartridge does not read the same.
- `dev:zapper-light`: pointed at the white half it sees light, after 226
  reads pointed high and 1135 pointed low; pointed at the black half it
  sees none; native == sandbox.
- `engine:devices`: each schedule written as a Chimera movie with only the
  machine's active controls, played by chimera-run in a project with the
  device in its port, ends on the native reference's RAM.

Seen to fail, all four at once with the adapter broken on purpose in four
places and rebuilt: the Four Score's players 1 and 3 swapped
(`dev:fourScore`); the Zapper's Y taken from its X (`dev:zapper-light`:
the same count high and low); the knob at half its place (`dev:arkanoid`:
0x73, not 0x93); the Zapper's axes said inactive (`engine:devices`). Put
back: 40 ok, 0 failed with `CHIMERA_ROOT`.

## 2026-10-31: the PPU bus

A second bus, "PPU Bus": the picture chip's 16 KiB as it sees them - the
cartridge's pattern tables at $0000-$1FFF, the nametables at $2000-$3EFF
(the console's 2 KiB or the cartridge's, as the mapper wires them, mirrors
included) and the palette at $3F00-$3FFF. It is read and written through
the accessors Mesen's own debugger uses (`NesConsole::DebugReadVram` and
`DebugWriteVram`), which do not tell the mapper an address went by, so no
MMC3 scanline counter moves when a tool looks. Writes land in CHR RAM or
ROM, the nametables and the palette; the PPU's registers are not on this
bus. The memory domains stay as they were (CIRAM, PALRAM, OAM, CHR RAM/ROM).

Checks:

- `bus:ppu-look`: the whole PPU bus read after each of Nova's 3000 frames
  leaves the machine as it was, and reads the same in both flavors;
- `bus:ppu`: on the input test cartridge, $0000-$1FFF is the CHR RAM
  domain, $2000-$23FF the first KiB of CIRAM (its 480 white tiles),
  $3F00-$3F1F the palette with its four mirrored entries; native == sandbox;
- `engine:movie` now also reads $2000-$23FF of the PPU bus through
  chimera-run and finds the first KiB of CIRAM.

Seen to fail: the PPU bus answered with the CPU's bus (`bus:ppu` and
`engine:movie` failed); the PPU bus read the way a game reads VRAM, by
writing the address to $2006 and reading $2007 (`bus:ppu-look` failed: the
picture and CHR RAM changed). A first break, a read of $2002 before each
byte, was NOT caught: Nova does not poll $2002 at the end of a frame, so
clearing the vertical blank flag there changes nothing in its run. The
check proves that the reads Chimera makes leave this game's machine alone,
not that every side effect would show.

## 2026-10-31: the owner's decisions on the devices (user-decided, 2026-10-31)

The owner accepted the second round's recommendations:

- **Where the Zapper and the Arkanoid controller plug in**: the NES's
  second controller port only, as built. The Famicom's expansion port and
  its devices (the Famicom Zapper, the Famicom Arkanoid controller, the
  four-player adapter) come next, as work that needs no game files.
- **The ranges of their axes**: the Zapper's place stays 0 to 65535 across
  the picture's width and height, and the Arkanoid knob 0 to 160 (the
  quickerNES core's range), as built.

Nothing changed in the core for these two: they keep what the second round
built.

## 2026-10-31: the Famicom's expansion port

The Famicom has a socket on its front, the expansion port, where Japanese
games' extra devices plug in. A new setting, `expansion` ("Expansion
Port"), says what is in it:

- **Nothing** (the default; a project made before has nothing there);
- **the Famicom Zapper**: the Zapper made for that port. It answers on
  $4017's bits 3 (light) and 4 (trigger), as the NES Zapper in port 2 does;
- **the Famicom Arkanoid controller**: its button on bit 1 of $4016, its
  knob's eight bits on bit 1 of $4017, inverted, highest bit first. Patch
  0007 already makes its knob the frame's own input, as for port 2's;
- **the four-player adapter** (Mesen's `FourPlayerAdapter`, Hori's): four
  pads read on bit 1 of $4016 (players 1 and 3) and $4017 (2 and 4), then a
  signature, as the Four Score does on bit 0, with the two signatures the
  other way round.

Mesen plugs the expansion port in whatever console it emulates; the core
keeps Mesen's console type (an NES, `Nes001`) and does not switch to a
Famicom's, so the reads' timing is the one every earlier check measured.

The controls, added at the end of the wire so movies made before keep
their columns: Expansion Trigger (T) and Expansion Fire (F), axes Expansion
Zapper X and Y (0 to 65535 across the picture, as port 2's) and Expansion
Paddle (0 to 160), headed EZX, EZY and EPad. They belong to the console's
group of a movie entry (they are in no player's list): the port is the
console's, and in player 2's group they would share the letters T and F
with port 2's devices. The four-player adapter uses players 1 to 4's pads;
with a pad also in a controller port, that pad and the adapter's first
are one player, pressed together. `IsButtonActive` and `IsAxisActive` say
which of the new controls the machine has. The mouse is bound to the new
ones by default, as to port 2's. The texts (five new keys) are in all 26
tables, with Famicom, Zapper and Arkanoid kept whole.

The harness's input files gained `t`, `f`, `X=`, `Y=` and `k=` for the
expansion port's trigger, button, Zapper place and knob.

Checks:

- `dev:famicomZapper`, `dev:famicomArkanoid`, `dev:fourPlayerAdapter`: as
  for port 2's devices, on the input test cartridge: the same machine
  natively, sandboxed and sandboxed with a save and a load around every
  frame; the RAM shows the last frame's controls; a plain pad in their place
  does not read the same.
- `dev:famicomZapper-light`: pointed at the white half high it sees light
  after 226 reads, low after 1135, never on the black half (the same counts
  as port 2's Zapper); native == sandbox.
- `engine:devices` now plays all six devices' schedules as Chimera movies.
- `expansion:frontend` (`run-frontend.sh`): the four-player adapter in a
  project opened in Chimera's window, P3 Right and P4 Start held through the
  window, ends on the native reference's RAM, which is not the idle run's.

Seen to fail, with the adapter broken on purpose in four places at once and
rebuilt: the adapter's players 1 and 3 swapped (`dev:fourPlayerAdapter`);
the Famicom Zapper's Y taken from its X (`dev:famicomZapper-light`: 1021
reads high and low alike); the Famicom knob read from port 2's paddle
(`dev:famicomArkanoid`: 0xa4, not 0x93); the expansion Zapper's axes said
inactive (`engine:devices`). 42 ok, 4 failed; put back, 46 ok.

For the window check, a first break was NOT caught: players 3 and 4 said
inactive under the adapter. The window's Lua script presses buttons whether
or not the core says they are there, so `expansion:frontend` proves the
machine the window builds, not the list of active controls (which
`engine:devices` proves). A second break, the expansion setting ignored in
the guest only, was caught (5 ok, 1 failed). After both breaks the package
was rebuilt and is byte for byte the one tested (SHA-1 89a2a7a5).

Measured: `run-gate.sh` 46 ok with `CHIMERA_ROOT` (40 without),
`run-frontend.sh` 6 ok, `test-packages` 21 PASS, `check-core-texts.py` 45
keys, `check-names.py` 0 in 26 tables, `check-proper-nouns.py` 0.

Not tried: any real game with these devices (none is in this repository;
Japanese games that use them are commercial). Not offered yet: the
two-player mode of the adapter, the Family BASIC keyboard and the other
expansion devices Mesen has (Oeka Kids tablet, Family Trainer mat, Hyper
Shot, Party Tap and more).

## 2026-10-31: EPSM songs made with FamiStudio

The owner gave FamiStudio 4.5.3 (MIT, by BleuBleu): its Linux build, and
from its repository the EPSM cartridge shells (`rom_epsm_ntsc.nes`,
`rom_epsm_pal.nes`), two EPSM test songs (`TestEPSM.fms`,
`TestMultiEPSM.fms`) and an EPSM instrument set. FamiStudio exports a song
to a playable .nes cartridge: its sound engine and player in the shell,
the song's data added. That would be EPSM music made by a tool other than
ours, and, all of it being MIT, could go into `tests/` with FamiStudio's
licence beside it.

**The songs were not exported.** Running FamiStudio's program (with the
.NET runtime) on this machine was refused by this session's permission
system, as code from outside the repository; it was not tried another way.
So no FamiStudio song has been run, and nothing of FamiStudio is in this
repository. The command, from the program's own help text (not run):
`dotnet FamiStudio.dll TestEPSM.fms rom-export TestEPSM.nes
-rom-export-mode:ntsc` (or `pal`).

What was run instead, from copies in a scratch folder: the two shells as
they are. Each is an NES 2.0 cartridge (mapper 5, 32 KiB of program,
8 KiB of CHR) with the EPSM in its header; its program holds FamiStudio's
EPSM driver (stores to $401C-$401F) and its song area is empty. Mesen
plugs the EPSM in, and the player draws FamiStudio's screen. It plays about
six seconds of sound and then nothing, but that sound is the console's own:
the same shell with the EPSM taken out of its header sounds the same (RMS
474.2 both ways over 10 seconds with nothing pressed; over the check's 30
seconds the difference between the two has an RMS of 0.3 for the NTSC
shell and 2.5 for the PAL one, against 274.9 and 236.0 for the sound). With no song the player also ignores the pad
(the RAM after 900 frames with buttons held is the idle run's). The shells
are FamiStudio's code running in the sandbox, not EPSM music.

The tests for the exported songs are ready and take the folder from
`MESEN_FAMISTUDIO_ROMS` (SKIP without it); `docs/BUILDING.md` has the
commands. For each .nes in it:

- `famistudio:<name>:equivalence`: 1800 frames (30 seconds) of the pad
  exercise, native == sandbox (picture, sound, lag, every memory domain),
  and a save and a load around every frame change nothing;
- `famistudio:<name>:session`: a state saved at frame 900 by one process
  and loaded by another ends on the straight run's machine;
- `famistudio:<name>:epsm`: the EPSM plays: the sound minus the sound of
  the same cartridge with the EPSM taken out of its header has an RMS of
  300 or more (`waterbox/tests/audio-diff.py`);
- `engine:famistudio` (with `CHIMERA_ROOT`): a 900-frame movie made into a
  project by one chimera-run and replayed by another ends on the native
  reference's RAM, with the EPSM; it says for how many cartridges the
  movie's buttons changed the RAM at all;
- `famistudio:frontend` (`run-frontend.sh`): each cartridge in Chimera's
  window ends on the native reference's RAM after 300 frames, with the EPSM.

Run on the two shells as the folder: equivalence and session pass for both,
`engine:famistudio` and `famistudio:frontend` pass (the buttons changed the
RAM of 0 of them), and `epsm` FAILS for both ("the EPSM added nothing
loud"), which is right: the shells play no EPSM note. That is how the
`epsm` check was seen to fail. The others were seen to fail with a guest
broken on purpose (a RAM byte bumped every frame, the native reference
left alone): both `equivalence` checks, `engine:famistudio` and
`famistudio:frontend` failed; `session` passed, as it should, since it
compares the sandbox with itself.

Before an exported cartridge goes into `tests/`: compare it with the shell
it was made from, byte for byte, and check that every byte that differs is
in the song area and the title text (the song's data and names, MIT), so
that the rest is FamiStudio's code only; then put FamiStudio's `LICENSE`
beside it (`tests/roms/famistudio-LICENSE`) and credit it in
`tests/roms/README.md`. Not done: there is no exported cartridge yet.

## 2026-10-31: FamiStudio may export the test songs (user-decided, 2026-10-31)

The owner allowed, on 2026-10-31 (asked and answered in the owner's
session, passed to the fourth round), running FamiStudio 4.5.3's Linux
build on this machine to export songs. Only its command-line export is
allowed, for example
`dotnet FamiStudio.dll <song.fms> rom-export <out.nes> -rom-export-mode:ntsc`
(and `pal`), under the memory cap, from the copy unpacked in the third
round under `build/famistudio`. Nothing else from FamiStudio is run.

**It was refused again.** The fourth round copied `TestEPSM.fms`,
`TestMultiEPSM.fms`, `Instruments EPSM.fms`, the two shells and
FamiStudio's `LICENSE` into `build/famistudio/songs` and ran, once:

```
env -u DISPLAY -u WAYLAND_DISPLAY HOME=build/famistudio/home \
  XDG_CONFIG_HOME=build/famistudio/home/.config \
  systemd-run --user --scope --quiet -p MemoryMax=8G -p MemorySwapMax=0 \
  /usr/bin/dotnet build/famistudio/unpack/FamiStudio.dll \
  build/famistudio/songs/TestEPSM.fms rom-export \
  build/famistudio/export/TestEPSM-ntsc.nes -rom-export-mode:ntsc
```

(with absolute paths). This session's permission system refused it before
it ran, as "Code from External". As the rules of the work say, it was not
tried another way, and the round stopped there: no song was exported, so
none was run, compared with its shell or committed. The owner's permission
reached the agent through the task, not through the permission system;
for the export to run, the permission has to be given there (a rule
allowing that command in the session's settings), or the owner exports
the songs and hands over the .nes files.

## 2026-10-31: the owner's files, fifth round

The owner gave, for local tests only (they stay outside this repository;
`MESEN_CONTENT_DIR` names the folder, `docs/BUILDING.md` lists the files):
the real YM2608/YMF288 rhythm ROM, an EPSM game (Sonic The Hedgehog,
"FAMICOM 60 PIN GAME"), Duck Hunt, the Famicom Disk System's BIOS with Ai
Senshi Nicol, both Arkanoids and four four-player games.

### The rhythm ROM pinned

The file's SHA-1, 50b6c3e288eaa12ad275d4f323267bb72b0445df, is now pinned
in `waterbox.config`, with `ym2608_adpcm_rom.bin` as the name it usually
has. The core still mounts it under the id `ymf288_adpcm_rom.bin`, the name
Mesen reads. Chimera's firmware window takes only that file now; chimera-run
mounts whatever it is given and records its hash, so the made-up 8 KiB
stand-in stays where no Chimera is involved (`epsm:firmware`, native and
sandbox) and the checks through Chimera use the real file
(`engine:epsm-firmware`, `epsm:frontend`; SKIP without it). The window's
`epsm:frontend`, which used the made-up file, now needs the real one.

Measured (`epsm:real-rhythm`): the EPSM test program's drums with the real
ROM, native == sandbox, sound RMS 1847.8 against 4212.5 with no ROM (Mesen
then plays zeros as ADPCM, which is not silence) and 4465.4 for the
difference.

### How Mesen decides to plug the EPSM in

From MesenCE's source at the pin: only the header. `NesHeader::HasEpsm` is
true for an NES 2.0 header with console type 3 and extended console type 4;
the game database (`MesenNesDB.txt`, 10655 games) has no field for it and
does not hold Sonic's CRC32 (DB358674) anyway; there is no setting. In
Mesen a person with a plain iNES file edits the header (the debugger's NES
Header Editor offers "EPSM Module" as the console type) and saves the file.

So the core does it with a setting, as the owner suggested, needing nothing
of Chimera: **Expansion Port** gains **EPSM**. Patch 0008
(`MESEN_EXPANSION_EPSM`) adds a flag the host sets before loading; the
mapper then builds the EPSM as for such a header. A header that asks for the
EPSM still gets it whatever the setting says, as in Mesen.
`SuggestSettings` proposes `expansion: epsm` and `epsmDrums: on` for a
plain header whose program has 8 or more stores to $401C-$401F (STA, STX,
STY absolute, STA indexed); EPSM programs have many (this repository's test
program 92, FamiStudio's driver 70), other games none (0 in each of the
owner's ten other files and the homebrew here). It cannot tell a game that
reaches the chip only through $4016.

Checks: `epsm:expansion` - the test program with a plain header and the
setting sounds sample for sample as with the EPSM header and gets the
timer's 56 IRQs; `engine:suggest` - the suggestion for that file, through
chimera-run.

### Sonic The Hedgehog: the EPSM plugged in, and nothing written to it

With the setting, the core plugs the EPSM in for Sonic and the rhythm ROM
is loaded (the log says both); 1800 frames of the pad exercise reach the
first level; native == sandbox == saved and loaded each frame; a state
crosses processes; a 1200-frame movie made into a project by chimera-run and
replayed by another ends on the native RAM; in Chimera's window the RAM is
the native one. **But this file plays no EPSM note.** Its sound with the
EPSM and without is the same sample for sample (difference RMS 0.0 over
1800 frames), and its program has nothing that could reach the chip: no
store to $401C-$401F (absolute, indexed or through a pointer to page $40),
and its five stores to $4016 write only 1 and 0 (the pads' strobe), never
OUT1. Its RAM and work RAM hold no such code either. This copy is a game
that runs on the 2A03's sound; either it is not the EPSM version, or the
EPSM version is another file. The EPSM is proved on this repository's test
program with the real rhythm ROM, not on a game.

### The Famicom Disk System

- `.fds` files (with fwNES's header or without) go in the cartridge slot;
  the BIOS is the firmware `disksys.rom`, SHA-1
  57fe1bdee955bb48d357e463ccbf129496930b62 pinned, required when the slot
  holds an .fds file (`requiredWhen: {"slot": "rom", "extension": "fds"}`).
  Without it the core says so (`error.no_fds_bios`) instead of Mesen's
  bare refusal.
- The drive, as the other disk cores in Chimera do it (PUAE, VICE): three
  buttons in the console's group, added at the end of the wire - Previous
  Disk (`<`), Next Disk (`>`) move a selector over the disk's sides; Eject
  Disk (`e`) takes the disk out when pressed and puts the selected side in
  when let go. The selector lives in guest memory, so states and rewind
  carry it. They are active only for a Disk System game. Side A is in the
  drive at power on (Mesen's `FdsAutoLoadDisk`); Mesen's automatic side
  changes stay off (they are off anyway while a movie plays or records in
  Mesen), so the movie says when a side changes.
- Not done: the drive light and the drive's media list
  (`GetDrive*` exports: Mesen keeps the motor's state private), and what
  the game writes to the disk is kept in memory and lost at the end of the
  session (no export).

Ai Senshi Nicol (`game:fds-nicol`): Start on the title (frames 1800 and
1850), the story plays, the game asks "PLEASE SET DISK B" at about frame
3700; Eject Disk held from 3800 for 60 frames with Next Disk pressed puts
side B in, and from about 5500 stage 1 is played (Right held from 5700).
Native == sandbox == saved and loaded each frame; a state saved at 4500
crosses processes; the last picture has 13 colours (the prompt and the
BIOS's error screen have 2). The same schedule as a Chimera movie, its disk
columns included, replayed by chimera-run ends on the native RAM
(`engine:fds-nicol`); 300 frames in the window too (`fds:frontend`).

Traps: with the disk taken out too early the BIOS shows ERROR.07 (wrong
side) alternating with the prompt. And the harness runs as many frames as
its input file has, whatever `--frames` says: pictures taken with
`--frames N` of a longer file are the file's last frame (this cost a round
of wrong conclusions here; cut the file).

### The devices in real games

- **Duck Hunt** (`game:duckhunt`), the Zapper in port 2: Game A, the first
  duck's sprites read from OAM at frame 760 (middle x 172, y 118), the
  Zapper pointed there through its axes (44032, 32222) and the trigger
  pulled: the duck falls and the score is 500 ($00C5 = 5). The same shot at
  the sky misses (0). Native == sandbox.
- **Arkanoid** (`game:arkanoid`), the Arkanoid controller in port 2: the
  paddle's left edge at x 16 with the knob at 0, x 160 with it at 160.
  **Arkanoid II** (`game:arkanoid2`), the Famicom's on the expansion port:
  x 12 and x 154. Arkanoid II takes the knob only when the game is started
  with the knob's button; started with the pad's Start it plays with the
  pad. Native == sandbox.
- **Four players** (`game:rcproam2`, `game:indyheat`), the Four Score: on
  the screen where players join, P3 and P4 press Start and R.C. Pro-Am II
  shows their initials being entered and Indy Heat their cars' name panels
  (seen in the pictures); the machine differs from the run without those
  presses, and with plain pads instead of the Four Score the presses reach
  nothing. Native == sandbox. Super Off Road and Kings of the Beach were not
  tried.

### Seen to fail

One build broken on purpose in eight places at once (the EPSM setting
ignored, Next Disk doing nothing, the Zapper's Y always 0, the knob at half
its place, the Four Score's players 3 and 4 given players 1 and 2's pads,
the suggestion's threshold out of reach, the EPSM's volume 0, the Eject
Disk button said inactive) and a package with a wrong rhythm ROM pin:
`run-gate.sh` 35 ok, 22 failed, among them every new check
(`epsm:expansion`, `epsm:real-rhythm`, all eight `game:` checks,
`engine:suggest`, `engine:epsm-firmware`, `engine:sonic-epsm`,
`engine:fds-nicol`). `game:fds-nicol` first PASSED with Next Disk broken:
it only asked that the side change changed the machine, and putting side A
back in does too. It now asks for stage 1's picture, and failed then (2
colours). The window test on the broken package: `sonic:frontend` failed;
`epsm:frontend` (it compares RAM, and the volume does not reach RAM) and
`fds:frontend` (no side change in 300 frames) did not. `texts:names` failed
on the new texts first: "BIOS" bent in Polish, Romanian and Norwegian
(seven texts) once BIOS and Disk System were added to its names.

## Where it stood after the fifth round (2026-10-31)

Works, and is tested here on Linux against Chimera main cb46d2b7
(`~/chimera-scratch-bump`):

- Mesen's NES in the sandbox, identical to the native reference on the
  homebrew, the EPSM test program, the input test program and, new, eight
  of the owner's commercial games; savestates within a process and across
  processes; turbo; virtual time; settings; saved games.
- The EPSM: by the NES 2.0 header, or, new, by **Expansion Port = EPSM**
  for a plain header (patch 0008), suggested when the program writes the
  EPSM's registers. The real rhythm ROM is pinned (SHA-1 50b6c3e2...) and
  plays the test program's drums.
- New: the **Famicom Disk System** - .fds games, the BIOS as pinned
  firmware, side changes by Previous Disk, Next Disk and Eject Disk. Ai
  Senshi Nicol plays stage 1 after its side change, natively, sandboxed,
  through chimera-run's movies and in the window.
- The devices in real games: Duck Hunt (a duck hit through the Zapper's
  axes), Arkanoid and Arkanoid II (the knob moves the paddle, port 2 and
  the expansion port), R.C. Pro-Am II and Indy Heat (players 3 and 4 join
  through the Four Score).
- Two buses, no network code, the package and its contract tests, texts in
  26 languages with every name unbent.
- Commands and counts: `run-gate.sh` 57 ok with `CHIMERA_ROOT` and
  `MESEN_CONTENT_DIR`, 47 ok with Chimera only, 41 ok with neither;
  `run-frontend.sh` 8 ok with the content, 5 ok without; `test-packages`
  22 PASS; `check-core-texts.py` 51 keys; `check-names.py` 0 in 26 tables;
  Chimera's `check-proper-nouns.py` 0.

Not done, or not proved:

- **No EPSM music from a game.** The Sonic The Hedgehog file the owner gave
  has no EPSM code (see "Sonic The Hedgehog: the EPSM plugged in, and
  nothing written to it"): with the EPSM plugged in it sounds exactly as
  without. The EPSM is proved on this repository's test program, with the
  real rhythm ROM. An EPSM build of a game (or FamiStudio's exported songs)
  is still needed before publishing, by the owner's rule.
- **No FamiStudio song has been run.** `build/famistudio/export/` was still
  empty this round; FamiStudio was not run (the permission system refused
  it twice before). The checks are ready.
- The suggestion cannot tell a game that writes the EPSM only through
  $4016.
- The Disk System's drive light and media list are not exported; what a
  game writes to its disk is lost at the end of the session.
- Not tried: Super Off Road, Kings of the Beach; the Four Score in a race
  (only the join screens); a .zip game file (the Duck Hunt check takes the
  .nes out of the zip itself; the core does not open archives).
- **Windows** has not been run; the owner wants a run before publishing.
- Mesen's other systems are compiled in and refused at load.
- The window checks `epsm:frontend` and `fds:frontend` were not seen to
  fail (see "Seen to fail" above); `expansion:frontend` proves the machine,
  not the list of active controls.
- CI is written and has never run (no remote); without the owner's files
  the game checks SKIP there, and so does `epsm:frontend`, which needs the
  real rhythm ROM now that it is pinned.

Next, in order: an EPSM game that writes the chip (from the owner), or
FamiStudio's exported songs; a Windows run; then publishing as `mesen`
("Mesen"); then the SNES and the GBA.

Traps, for whoever continues (each one cost time here):

- Build both flavors before a test script: they build nothing and compare
  stale binaries.
- A build option a patch adds does nothing until `meson.build` defines it
  (patch 0007's was first left out, and the knob stayed where the mouse
  put it).
- Mesen's `SetPreferences` resets the firmware folder override; set the
  folders after the preferences.
- An input provider registered before the game loads goes nowhere, and a
  power cycle makes a new console: register after both.
- The core's NES config defaults are not the UI's (volumes 0, no palette).
- A path "./name" is not a mount's name: patch 0004.
- Nova writes into its battery RAM from the fourth frame after power on.
- The harness runs the larger of `--frames` (600 when not given) and the
  input file's length. (This log said before that the file's length did
  not count; it does.)
- The window needs Qt's libraries: `--qt-lib`.
- The language tables: an ending glued to a name hides behind a sign too
  ("YMF288:n", "EPSM's", "Mesen'in"); Chimera's checker sees only letters.
- `systemd-run --scope` does not keep the shell's working folder for the
  command it runs here: give the runners absolute paths.
- The package's SHA-1 changes with every commit (its version is the
  commit): compare packages built at the same commit only.
- FamiStudio's bare shells have the EPSM in their header and its driver in
  their program, but play no EPSM note: a check that only asks "is the
  EPSM plugged in" passes on them; ask what the EPSM added to the sound.
- The harness runs as many frames as its input file has: `--frames N` with
  a longer file still runs the whole file, so a picture "at frame N" is the
  file's last frame. Cut the file to N lines.
- A disk-side check must ask for what the right side brings (here the
  stage's picture): putting the wrong side back in also changes the machine.
- Arkanoid II takes the knob only when started with the knob's button.
- chimera-run takes any firmware file it is given and records its hash; the
  pinned SHA-1 is enforced by Chimera's firmware window, not by chimera-run.



## Questions for the owner

The three questions of the first round and the two of the second were
answered on 2026-10-31; see the owner's decisions above.

Open:

- The Sonic file has no EPSM code. Is there an EPSM build of it (or
  another EPSM game) to try? Until then no game has played EPSM music here.
- FamiStudio's export: still not run (refused by the permission system in
  rounds 3 and 4; the export folder was empty in round 5). Will the owner
  export the songs, or add a permission rule for the command?


## Published without a real EPSM game (user-decided, 2026-10-31)

The owner, on being told that the Sonic file has no EPSM code and that no
game has played EPSM music here: "Just publish as if we succeeded. Let users
steer it from now by issues." So the core is published now, and what was not
proved is said plainly in the README and on the request (issue 410): the
EPSM is proved on this repository's test program with the real rhythm ROM,
and no game's EPSM music has been heard. Users who have EPSM games are asked
to report what they find.

The owner also accepted, the same day: the core does not open .zip game
files (people unzip them; Chimera hashes the file it is given).

Windows, run by the main session before publishing with the published
Chimera for Windows (Development build cb46d2b7, chimera-run.exe): a project
of Nova the Squirrel run 3000 frames, and a project of the EPSM test program
with EPSM Drums on and the real rhythm ROM given as firmware run 600 frames
("[mesen] EPSM rhythm ROM loaded"), each end on the same RAM as the same
projects run by chimera-run on Linux (byte for byte). Sound was not compared
on Windows.

## Every system Mesen emulates (user-decided, 2026-10-31)

The owner, on 2026-10-31: "I want all its systems to be offered in the
chimera core." This replaces the earlier decision of the first round
("the NES only until the EPSM is proved on a real game; then the SNES and
the GBA"): every system MesenCE emulates is offered by this package.

What MesenCE emulates at the pinned commit (4b8a196e), from its source
(`Core/Shared/SettingTypes.h`, `ConsoleType`, and each console's
`GetSupportedExtensions`):

- the **NES** (`Core/NES`): with the Famicom Disk System, the VS System,
  the StudyBox, and NSF music files;
- the **Super NES** (`Core/SNES`): with its cartridge chips - the DSP-1,
  DSP-1B, DSP-2, DSP-3 and DSP-4, the ST010 and ST011 (NEC uPD7725 and
  uPD96050 running a program of their own), the ST018 (an ARM, its own
  program too), the Cx4, the SA-1, the Super FX, the S-DD1, the SPC7110
  (and its clock), the OBC1, the MSU-1 - the **Super Game Boy** and Super
  Game Boy 2 (a Game Boy game on the Super NES), the **Satellaview** (BS-X,
  .bs files) and the **Sufami Turbo** (.st), and SPC music files;
- the **Game Boy** and **Game Boy Color** (`Core/Gameboy`), and GBS music
  files;
- the **Game Boy Advance** (`Core/GBA`);
- the **PC Engine / TurboGrafx-16**, the **SuperGrafx** and the **PC Engine
  CD** (CD-ROM2, Super CD-ROM2, the Arcade Card, the Games Express card)
  (`Core/PCE`), and HES music files;
- the **Master System**, the **Game Gear**, the **SG-1000** and the
  **ColecoVision** (`Core/SMS`, one console with four models);
- the **WonderSwan** and **WonderSwan Color** (`Core/WS`, with the
  SwanCrystal and the Pocket Challenge V2 as models).

The music file players (NSF, SPC, GBS, HES) are not machines a movie is
made on and are not offered.

How the package offers them: one `machines` entry per system id, picked by
a new setting `machine` (the ares and Mednafen cores' shape). The NES is
the first machine and the setting's default, and it keeps the package's
top-level controller, picture and settings, so a project made before the
other machines existed is an NES project and plays as it did. The other
machines are added one step at a time, each committed when its checks
pass:

| Step | Machines (system ids) | Free test content |
| --- | --- | --- |
| 1 | Super NES (SNES), Super Game Boy (SGB) | this repository's test program |
| 2 | Game Boy (GB), Game Boy Color (GBC) | this repository's test program |
| 3 | Game Boy Advance (GBA) | none (Mesen needs the BIOS) |
| 4 | Master System (SMS), Game Gear (GG), SG-1000 (SG), ColecoVision (CV) | test programs (the ColecoVision needs its BIOS) |
| 5 | PC Engine (PCE), SuperGrafx (SGX), PC Engine CD (PCECD) | test program (the CD needs its BIOS) |
| 6 | WonderSwan (WS), WonderSwan Color (WSC) | test program |

## 2026-10-31: the machines, and the Super NES (sixth round, step 1)

### What stays the NES's

- The machine setting `machine` (options `nes`, `snes`, `sgb` so far)
  defaults to `nes`. The NES's settings (region, port1, port2, expansion,
  ramPowerOnState, epsmDrums) carry `when: ["nes"]`; their names, options
  and defaults are unchanged. The NES's controller stays the package's
  top-level `input` (its machine entry declares none), and `systemId` stays
  `NES`.
- `waterbox/mesen.cpp` takes the NES's path exactly as before when the
  machine is `nes`: the same configuration, the same wire, the same buses
  and domains. Measured: the published package's core.wbx (built at
  a874aa5, byte for byte the core.wbx of the package built then) and this
  one run Nova's 3000-frame schedule to the same frames, picture, sound,
  lag and every memory domain (`nes:published`); a project and movie made
  by chimera-run with the published package play in this package to the
  native reference's RAM (`engine:nes-published`). Every NES check passes
  as before.

### The adapter

- `waterbox/mesen.cpp` reads `machine` first. For a machine other than the
  NES it sets up Mesen's settings for that console as Mesen's UI does by
  default, with three exceptions said where they are made: frame blending
  is off (it mixes each picture with the one before, so a frame drawn
  after undrawn frames would not be its own picture), and the Game Boy
  Advance's and the WonderSwan's colour correction is off (their curve is
  computed with pow(), whose last bit the sandbox's C library and the
  host's do not always agree on: the WonderSwan Color's picture differed
  between the two flavors with it on). The picture keeps Mesen's UI's
  overscan (the lines a television hides): 7 lines at the top and 8 at the
  bottom of the Super NES's picture are cut, so it is 256x224.
- Each machine has its own wire: the console's buttons, then the same pad
  once per player, in the order Chimera's other cores use for the same
  console (snes9x's for the Super NES: Up Down Left Right Select Start Y B
  X A L R, letters U D L R s S Y B X A l r; Power P and Reset r).
- The game is the slot `cart` (the NES's stays `rom`). Mesen picks a
  console by the file's extension, so a file whose extension is not the
  machine's is given to Mesen from memory under the machine's (a
  ColecoVision game named .bin as .col); Mesen reloads a game by its path
  at a power cycle, so for those the core reloads it itself.
- Firmware Mesen cannot run without is checked before the load and named
  in the error (`error.no_snes_chip`, `error.no_sgb_bios`,
  `error.no_bsx_bios`, `error.no_sufami_bios`, ...): without it Mesen loads
  some games anyway and they wait forever for the chip.
- Memory domains per console (the Super NES: WRAM, Cart RAM, VRAM, OAM,
  CGRAM, APU RAM, and the chips' RAM when the cartridge has them; the
  Super Game Boy adds the Game Boy's as "GB WRAM" and the rest) and buses
  through the accessors Mesen's debugger uses (the Super NES's 16 MiB
  "System Bus" by `SnesMemoryManager::Peek` and its memory mappings'
  `DebugWrite`; the sound CPU's 64 KiB "APU Bus"; the Super Game Boy's
  "GB Bus").
- The frame rate as a fraction from each console's clocks
  (236250000/3931026 for an NTSC Super NES, 21281370/425568 for a PAL one).
- Save data: the cartridge's RAM, exported as battery.sav; the saved game
  slot takes .sav and .srm (Mesen asks the Super NES's as .srm).

### Two new patches

- **0009 `MESEN_VIRTUAL_CLOCK`**: the Game Boy's MBC3 clock, the SPC7110's
  RTC-4513 and the S-3511A (Game Boy Advance and WonderSwan cartridges)
  read the host's time. With the option they read `MesenVirtualClockMs`,
  which the core starts at the new setting **Clock Start** (`rtcStart`, a
  date and time, 2000-01-01 by default) and moves forward with the
  machine's frames. The Satellaview's date is the same setting (Mesen's
  `BsxCustomDate`).
- **0010 `MESEN_BARE_FOLDERLESS`**: Mesen names files beside the game by
  the game's folder (the MSU-1's tracks, a .cue's .img); for a game given
  by its bare name the folder is "", and `FolderUtilities::CombinePath`
  read the character before its start - native, the first Super NES game
  stopped on the C++ library's assertion. With the option the name stays
  as it is.

### The Super NES's chips: firmware for this game

The DSP-1 to 4, ST010, ST011 and ST018 run a program that is not in the
game's file. Which one a cartridge needs depends on the game, so the
package declares `"gameFirmware": true` and `SuggestSettings` returns the
chip's program as this game's firmware, read from the cartridge's header
the way Mesen reads it (`waterbox/snes-coprocessor.inc`: Mesen's header
score, ROM type and title). The SHA-1s are the owner's files'. The Cx4,
SA-1, Super FX, S-DD1, SPC7110 and OBC1 need none (Mesen emulates them
whole).

### The package

- Machines `SNES` ("Super NES / Super Famicom") and `SGB` ("Super Game
  Boy"), each with its controller ("SNES Controller", five players: the
  multitap in port 2 holds players 2 to 5), shown at 292x224.
- Settings (each with `when`): Region (`snesRegion`), Controller Port 1
  and 2 (`snesPort1`: controller or nothing; `snesPort2`: controller,
  nothing or the multitap), Memory at Power On (a second declaration of
  `ramPowerOnState`, random by default as Mesen's UI has it), Random Seed,
  Super Game Boy Model (`sgbModel`: Super Game Boy 2 or Super Game Boy),
  Boot ROM (`bootRom`: Mesen's own, from SameBoy, or Nintendo's as
  firmware) and Clock Start.
- Firmware: the Super Game Boy's and Super Game Boy 2's cartridge programs
  (SGB1.sfc, SGB2.sfc) and their boot ROMs, pinned to the owner's files;
  the Satellaview's BS-X BIOS and the Sufami Turbo's BIOS, required for a
  .bs and a .st file, with no SHA-1 pinned (nobody here has them).
- Default keys for the SNES Controller (player 1: the arrows, Z X A S Q W,
  Space and Enter, and a gamepad), written here.
- 56 new texts, in all 26 language tables; check-names.py knows the new
  names (Super NES, Super Famicom, Super Game Boy, Game Boy, Satellaview,
  BS-X, Sufami Turbo, DSP-1 to 4, ST010, ST011, ST018, SameBoy, and the
  next steps' names).

### The test program

`tests/snes-test/make-snes-test.py` builds `tests/roms/snes-test.sfc`: our
own 65816 program. Each frame it waits for the automatic read of the pads
to start and to end (read while it runs, the registers are not the pads':
a first version read 'Left' for a held Start), copies the read ($4218 to
$421F) to RAM, reads port 2 by hand sixteen times with the I/O line low
(a multitap's pads 4 and 5), shows pad 1 as the backdrop colour and writes
it to its battery RAM. The same program with the headers of the chip
games (DSP-1 to 4, ST010, ST011, ST018) is built at test time; on the
DSP-1 and DSP-1B ones it asks the chip to multiply 0x4000 by 0x4000.

### Checks (waterbox/tests/systems.sh, run by run-gate.sh)

- On the test program, two pads and then five through the multitap:
  `snes:equivalence`, `snes:input` (the RAM holds the last frame's buttons
  of every pad, and the idle run is another machine), `snes:savestate`,
  `snes:turbo`, `snes:session`, `snes:bus`; the same six for
  `snes-multitap`.
- `snes:chip-<chip>` for the eight chips (with the owner's files): the
  cartridge is refused without the chip's program and runs with it, native
  == sandbox; the DSP-1's and DSP-1B's programs multiply into 0x2000.
- The owner's games (MESEN_SYSTEMS_CONTENT): Super Mario World, The Last
  Super, Top Gear 2, Sailor Moon S, Prince of Persia (J), and Kirby's
  Hoshinoka-Bi on the Super Game Boy 2 and the Super Game Boy: 1800 frames
  of the pad exercise, native == sandbox == saved and loaded each frame,
  another machine than the idle run, a state across processes, sound, a
  picture of many colours.
- Through chimera-run: `engine:snes` and `engine:snes-multitap` (the
  schedule as a Chimera movie, made into a project by one chimera-run and
  replayed by another, ends on the native reference's WRAM, and that WRAM
  holds the schedule's last buttons), `engine:snes-polls` (the reads of
  the controls reach Chimera's input-poll callback), `engine:sgb` (Kirby's
  movie, with the Super Game Boy 2 program), `engine:nes-published`.
- In the window (run-frontend.sh): `snes:frontend` (P1 Right, P1 Start and
  P2 A held through the window), `snes-multitap:frontend` (P3 B and P5 L),
  `snes:keybinds`, `snes:game-frontend` (Super Mario World), `sgb:frontend`
  (Kirby with the Super Game Boy 2 program, nothing held).

Seen to fail, with the adapter broken on purpose in five places at once
and rebuilt (players 1 and 2 of the Super NES swapped, the multitap's
players one off, the chip check skipped, the Super NES bus read with
Mesen's ordinary `Read`, the Super NES's channel volumes 0): `snes:input`,
`snes-multitap:input`, both `snes*:bus`, all eight `snes:chip-*`, four of
the five Super NES games ("silent"), `engine:snes`, `engine:snes-multitap`,
`snes:frontend` and `snes-multitap:frontend` failed. The engine and window
checks at first PASSED with the swapped players (Chimera and the native
reference were broken alike); they now also read the test program's RAM
for the schedule's buttons, and failed then. Not broken on purpose:
`engine:snes-polls` (the hook is the NES's, which was seen to fail in the
third round) and the Super Game Boy checks.

Chimera: chimera-run --new-project records every setting the package
declares at its first declaration's default for the ones --settings leaves
out, the NES's included (the window's New Project uses the machine's own
defaults). So a Super NES project made by chimera-run says
ramPowerOnState "zeros" where the window would say "random"; both run as
recorded. The engine and window checks run the native reference with the
settings the project recorded.

## Where this stands (2026-10-31, sixth round)

Works, and is tested here on Linux against Chimera main cb46d2b7
(`~/chimera-scratch-bump`):

- Everything the fifth round left (the NES, the EPSM, the Disk System, the
  devices), unchanged: the NES machine is the published one (`nes:published`,
  `engine:nes-published`).
- New: the package is several machines, picked by the setting **Console**
  (`machine`). Offered so far: the **Super NES** (pads, the multitap, the
  chips' programs as each game's firmware, Clock Start for the SPC7110's
  clock and the Satellaview's date) and the **Super Game Boy** (Super Game
  Boy and Super Game Boy 2, Mesen's or Nintendo's boot ROM).
- Commands and counts: `run-gate.sh` 53 ok with neither Chimera nor the
  owner's files, 62 ok with Chimera, 90 ok with Chimera, MESEN_CONTENT_DIR,
  MESEN_SYSTEMS_CONTENT and MESEN_PUBLISHED_PACKAGE; `run-frontend.sh` 8 ok
  without the owner's files, 13 ok with them; `test-packages` PASS (0
  failed); `check-core-texts.py` 107 keys; `check-names.py` 0 in 26 tables;
  Chimera's `check-proper-nouns.py` 0.

Not done, or not proved:

- The other systems (steps 2 to 6 above): not offered yet.
- The Satellaview (.bs) and the Sufami Turbo (.st): declared, never run (no
  BIOS was given; the owner's two .bs games need the BS-X BIOS).
- The Super NES chips DSP-2, DSP-3, DSP-4, ST010, ST011 and ST018: their
  programs load and the cartridge runs, but no game with one was tried and
  their programs were not exercised (the DSP-1's and DSP-1B's multiply was).
  The Cx4, SA-1, Super FX, S-DD1, SPC7110 and OBC1 were not tried (no game
  with one is among the owner's).
- The Super NES test program makes no sound (it does not load a program
  into the sound CPU); the sound is proved on the owner's games only, so CI
  proves the Super NES's sound only as native == sandbox on silence.
- Nintendo's boot ROMs (Boot ROM = Nintendo's) were not run.
- The mouse, the Super Scope and the other Super NES devices Mesen has are
  not offered.
- No Windows run of the new machines.

Traps, new this round:

- chimera-run --new-project records the first declaration's default for a
  setting --settings leaves out, even one whose `when` is another machine's
  (the NES's ramPowerOnState "zeros" in a Super NES project); compare a
  project with a native run of the settings it recorded.
- The Super NES's automatic pad read runs for three lines after the
  vertical blank starts; a program that reads $4218 too early reads a
  shifting register.
- A run longer than its input file: the harness runs `--frames` when it is
  larger (the default is 600), so give `--frames` as the file's length.
- The WonderSwan's and Game Boy Advance's colour correction (pow()) differs
  in its last bit between the sandbox's C library and the host's: off.

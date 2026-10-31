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

## Where this stands (2026-10-31, second round)

Works, and is tested here on Linux against Chimera main cb46d2b7
(`~/chimera-scratch-bump`):

- Mesen's NES in the sandbox, identical to the native reference on two
  homebrew games, the EPSM test program and the input test program;
  savestates within a process and across processes; turbo; virtual time;
  the EPSM present or absent by the header; the rhythm ROM reaching the
  chip; settings; saved games in and out and across a power cycle.
- The ports: a pad, nothing, the Four Score (four pads), the Zapper, the
  Arkanoid controller; only the controls the ports hold are in a movie.
- Two buses: the CPU's 64 KiB and the PPU's 16 KiB.
- No network code in `core.wbx` (patch 0006, checked by `build:no-network`).
- The package, its contract tests, its texts in 26 languages with every
  name unbent (`texts:names`); chimera-run (input polls, suggestions,
  firmware, movies, the devices); Chimera's window (5 checks).
- Commands and counts: `run-gate.sh` 42 ok with `CHIMERA_ROOT` (36 ok
  without, and two lines skipped), `run-frontend.sh` 5 ok, `test-packages`
  21 PASS, `check-core-texts.py` 40 keys, `check-names.py` 0 in 26 tables,
  Chimera's `check-proper-nouns.py` 0.

Not done, or not proved:

- **No real EPSM game has been run.** The EPSM is proved on this
  repository's own test program only (FM, SSG, rhythm, $4016 writes, the
  timer IRQ). By the owner's decision the package is not published, and no
  other system is started, until a real EPSM game has run with the real
  `ymf288_adpcm_rom.bin`. Needed from the owner: an EPSM game or demo that
  may be used for testing, and the rhythm ROM (its SHA-1 then pinned in
  `waterbox.config`).
- **No commercial game has been tried**, and none of the devices has been
  tried with a real game (Duck Hunt, Arkanoid, a four-player game): they
  are proved on this repository's input test program.
- **Windows** has not been run (no Windows box in this round either); the
  owner wants a Windows run before publishing.
- Mesen's other systems are compiled in and refused at load. Next after
  the EPSM is proved: the SNES and the GBA (owner, 2026-10-31).
- Devices not offered: the Famicom expansion port (its Zapper, Arkanoid
  controller, four-player adapters, keyboards), the Power Pad, the Zapper
  pointed off the screen (it can point at a black part of the picture),
  and the Famicom Disk System (it needs its BIOS, not given yet).
- `bus:ppu-look` would not catch every side effect: a read of $2002 per
  byte went unseen on Nova (see "the PPU bus").
- CI is written and has never run (no remote).
- Upstream's own test ROM suite is not run (the ROMs are not in MesenCE).

Next, in order: an EPSM game and the rhythm ROM from the owner; a Windows
run; then publishing as `mesen` ("Mesen"); then the SNES and the GBA.
Content-free work that could come before: the Famicom expansion port's
devices, the Zapper off the screen, the Power Pad.

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
- The harness runs 600 frames unless told (`--frames`), whatever the input
  file's length: an input file's last line is not the last frame then.
- The window needs Qt's libraries: `--qt-lib`.
- The language tables: an ending glued to a name hides behind a sign too
  ("YMF288:n", "EPSM's", "Mesen'in"); Chimera's checker sees only letters.

## Questions for the owner

The three questions of the first round (the fork, the licence, the network
code) were answered on 2026-10-31; see "the owner's decisions" above.

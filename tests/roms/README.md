# Test cartridges

All of these may be distributed. None is a commercial game.

- `nova.nes` - Nova the Squirrel by NovaSquirrel.
  https://github.com/NovaSquirrel/NovaTheSquirrel ,
  https://novasquirrel.itch.io/nova-the-squirrel . The code is GPL-3.0; the
  graphics and music are CC BY-NC 4.0 (not for commercial use). It is here
  under its author's terms, not under this repository's licence. The same
  file is in the quickerNES core's repository.
- `sprilo.nes` - Sprilo by cbrwn, from the GitHub Game Off 2017
  (https://github.com/cbrwn/gameoff , https://itch.io/jam/game-off-2017).
  No licence is stated (the repository had no licence file when the
  quickerNES core took it, 2026-10-13); it is here as its author published
  it, for free download, and not under this repository's licence.
- `epsm-test.nes`, `epsm-absent.nes`, `epsm-no4016.nes` - this
  repository's own EPSM test program, built by
  `tests/epsm-test/make-epsm-test.py`. The first two differ only in their
  header (the first says it has the EPSM); the third has the EPSM header and
  its writes through $4016 never reach the chip.

- `input-test.nes` - this repository's own input test program, built by
  `tests/input-test/make-input-test.py`: it keeps what it reads from both
  controller ports in its RAM, for the pad, the Four Score, the Zapper and
  the Arkanoid controller.

The input schedules in `tests/inputs/` were written for this repository.

- `snes-test.sfc` - this repository's own Super NES test program, built by
  `tests/snes-test/make-snes-test.py`: it keeps what it reads from the
  controller ports (two pads, or five through the multitap) in its RAM and
  shows pad 1 as the backdrop colour. The same script builds, at test time,
  the same program with the headers of the cartridges that have a DSP-1 to
  4, ST010, ST011 or ST018 chip.
- `gb-test.gb` - this repository's own Game Boy test program, built by
  `tests/gb-test/make-gb-test.py`: it keeps the buttons it reads in its RAM,
  shows and sounds them, and notes which console the boot program says it
  runs on. The same file is the Game Boy Color's test.
- `sms-test.sms`, `gg-test.gg`, `sg-test.sg`, `cv-test.col` - this
  repository's own Z80 test program for the Master System, Game Gear,
  SG-1000 and ColecoVision, built by `tests/sms-test/make-sms-test.py`: it
  keeps what it reads from the controllers in its RAM and shows and sounds
  player 1's buttons. The ColecoVision's runs only with the console's BIOS.
- `pce-test.pce`, `sgx-test.sgx` - this repository's own PC Engine test
  program (the same file twice), built by `tests/pce-test/make-pce-test.py`:
  it reads the controller port as a game reads the multitap and keeps the
  five pads in RAM, and shows and sounds pad 1.
- `ws-test.ws` - this repository's own WonderSwan test program, built from
  `tests/ws-test/ws-test.asm` by `tests/ws-test/make-ws-test.py` (with
  nasm): it keeps the three groups of buttons in RAM and shows and sounds
  them, and notes the SwanCrystal's mark. It is the test of both WonderSwan
  machines and of the Pocket Challenge V2 (it starts where that console
  starts a cartridge).
- `gba-test.gba` - this repository's own Game Boy Advance test program,
  built from `tests/gba-test/gba-test.s` by `tests/gba-test/make-gba-test.py`
  (with LLVM's clang, ld.lld and llvm-objcopy): it keeps the buttons and
  the cartridge clock's date and time in RAM, and shows and sounds the
  buttons. It needs no BIOS and holds no Nintendo logo.
- `snes-devices.sfc` - the Super NES test program reading the Super NES
  Mouse and the Super Scope, built by `tests/snes-test/make-snes-test.py`.
- `sms-phaser.sms` - a Master System program of this repository's own for
  the Light Phaser (a white screen, and where the gun sees light), built by
  `tests/sms-test/make-sms-test.py`.
- `pce-pad6.pce` - the PC Engine test program reading the port twice a
  frame, for the six-button Avenue Pad 6, built by
  `tests/pce-test/make-pce-test.py`.
- `gb-rtc.gb` - the Game Boy test program on an MBC3 cartridge with a
  clock, built by `tests/gb-test/make-gb-test.py`: it also reads the clock
  every frame.
- `ws-rtc.ws` - the WonderSwan test program on a Bandai 2003 cartridge with
  a clock, built from `tests/ws-test/ws-test.asm` (with `RTC` defined): it
  also reads the clock's date and time every frame.
- `nes-serial.nes`, `nes-oeka.nes`, `nes-boxing.nes`, `nes-mahjong.nes`,
  `nes-fbkey.nes`, `nes-suborkey.nes`, `nes-mic.nes`, `nes-dmc.nes` - this
  repository's own NES device programs, built by
  `tests/input-test/make-nes-devices.py`: each frame each talks to the
  controller ports the way one kind of device needs and keeps every byte
  it reads (`nes-mic.nes` is a mapper 188 cartridge, `nes-dmc.nes` plays
  a sample while it reads, for the console types).

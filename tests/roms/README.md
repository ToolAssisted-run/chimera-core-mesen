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

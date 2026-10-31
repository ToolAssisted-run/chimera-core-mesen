#!/bin/bash
# The core test script: the sandboxed core (core.wbx) must give the same
# frames, picture, sound, lag count and memory as the native reference built
# from the same sources, and must come back the same from a savestate.
# Every check says what it compared; the last line counts them.
#
# Content: free homebrew in tests/roms (Nova the Squirrel, Sprilo) and the
# EPSM test program this repository builds (tests/epsm-test). Input
# schedules are our own (tests/inputs, or the harness's pad exercise).
#
# Usage: ./run-gate.sh [-n <native build dir>] [-g <guest build dir>]
#   CHIMERA_ROOT=<a built Chimera checkout> and MESEN_PACKAGE=<the package>
#   add the checks that run through Chimera's engine (chimera-run).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
while getopts "n:g:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rn="$nat/run-native"
rw() { "$nat/run-wbx" "$gst/core.wbx" "$@"; }
digests() { grep -E '^(frames|vsync|videoHash|audioHash|audioSamples|lagFrames|domain\[)'; }
# what a turbo run can be held to: everything but the whole-run video hash
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|audioSamples|lagFrames|domain\[)'; }
# what a run that started from a state can be held to: the machine at the end
finalDigests() { grep -E '^(lastFrameHash|domain\[)'; }

ok=0
failed=0
report() { printf "%-26s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-26s %-6s %s\n" "Check" "Result" "Detail"
printf "%-26s %-6s %s\n" "-----" "------" "------"
short() { tr '\n' ' ' | head -c 140; }

# a work dir holding a cartridge as a project mounts it: the file under its
# name, the slot map, and the settings ($3, JSON; may be empty)
workdir() { # name rom settings
	local wd="$work/$1"
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$root/tests/roms/$2" "$wd/"
	printf '{"rom":["%s"]}' "$2" > "$wd/slots"
	[ -n "${3:-}" ] && printf '%s' "$3" > "$wd/settings"
	echo "$wd"
}

# ---------------------------------------------------------------- the machine
# name rom schedule(file in tests/inputs, or "exercise:N" frames)
tests=(
	"nova nova.nes nova.inputs"
	"sprilo sprilo.nes exercise:1200"
	"epsm epsm-test.nes exercise:600"
)
for t in "${tests[@]}"; do
	read -r name rom sched <<< "$t"
	wd="$(workdir "$name" "$rom")"
	case "$sched" in
		exercise:*) args=(--frames "${sched#exercise:}" --exercise) ;;
		*) args=(--inputs "$root/tests/inputs/$sched") ;;
	esac
	echo "${args[*]}" > "$work/$name.args"

	if ! "$rn" "$wd" "${args[@]}" 2>"$work/err" | digests > "$work/$name.nat"; then
		report "$name:equivalence" FAIL "native runner error: $(head -1 "$work/err")"; continue
	fi
	if ! rw "$wd" "${args[@]}" 2>"$work/err" > "$work/$name.raw"; then
		report "$name:equivalence" FAIL "sandbox runner error: $(grep -v '^\[mesen\]' "$work/err" | head -1)"; continue
	fi
	digests < "$work/$name.raw" > "$work/$name.box"
	frames="$(sed -n 's/^frames=//p' "$work/$name.box")"
	# a run that reported no frame compared nothing (gates.md, C)
	if [ -z "$frames" ] || [ "$frames" = 0 ]; then
		report "$name:equivalence" FAIL "the sandbox reported no frame"; continue
	fi
	if cmp -s "$work/$name.nat" "$work/$name.box"; then
		report "$name:equivalence" PASS "$frames frames, native == sandbox (picture, sound, lag, every domain)"
	else
		report "$name:equivalence" FAIL "$(diff "$work/$name.nat" "$work/$name.box" | short)"
		continue
	fi

	# the schedule must have shaped the machine: an idle run of the same length differs
	rw "$wd" --frames "$frames" 2>/dev/null | digests > "$work/$name.idle"
	if cmp -s "$work/$name.box" "$work/$name.idle"; then
		report "$name:input-shaped" FAIL "the input schedule changed nothing"
	else
		report "$name:input-shaped" PASS "an idle run of $frames frames is another machine"
	fi

	# a save and a load around every frame change nothing
	if rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$name.rr" && cmp -s "$work/$name.box" "$work/$name.rr"; then
		report "$name:savestate" PASS "a save and a load around each of $frames frames change nothing"
	else
		report "$name:savestate" FAIL "$(diff "$work/$name.box" "$work/$name.rr" | short)"
	fi

	# turbo: no picture for the first half; the machine, the sound and the
	# second half's pictures are the same, and the first half really went
	# undrawn (the whole-run picture hash differs)
	turboDigests < "$work/$name.raw" > "$work/$name.tn"
	if rw "$wd" "${args[@]}" --turbo 2>/dev/null > "$work/$name.traw"; then
		turboDigests < "$work/$name.traw" > "$work/$name.tt"
		nvh="$(grep -m1 '^videoHash=' "$work/$name.raw")"
		tvh="$(grep -m1 '^videoHash=' "$work/$name.traw")"
		if ! cmp -s "$work/$name.tn" "$work/$name.tt"; then
			report "$name:turbo" FAIL "$(diff "$work/$name.tn" "$work/$name.tt" | short)"
		elif [ "$nvh" = "$tvh" ]; then
			report "$name:turbo" FAIL "the turbo run drew every frame - nothing was skipped"
		else
			report "$name:turbo" PASS "half the frames undrawn; same machine, sound and later pictures"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi
done

# ---------------------------------------------------------------- savestates
# Session: the machine saved half way by one process, loaded by another and
# run to the end, is the machine of the straight run. The control loads the
# same state as if it had been taken ten frames earlier, with the schedule
# shifted: that must NOT land on the straight run.
wd="$work/nova"
read -r -a args < "$work/nova.args"
half=1500
finalDigests < "$work/nova.raw" > "$work/sess.straight"
rw "$wd" "${args[@]}" --save-at "$half" "$work/nova.state" > "$work/sess.save" 2>/dev/null
if ! grep -q "^savedAt=$half" "$work/sess.save"; then
	report "nova:session" FAIL "no state was saved at frame $half"
else
	rw "$wd" "${args[@]}" --load-at "$half" "$work/nova.state" 2>/dev/null | finalDigests > "$work/sess.loaded"
	rw "$wd" "${args[@]}" --load-at $((half - 10)) "$work/nova.state" 2>/dev/null | finalDigests > "$work/sess.shifted"
	if [ ! -s "$work/sess.loaded" ]; then
		report "nova:session" FAIL "the loading process reported nothing"
	elif ! cmp -s "$work/sess.straight" "$work/sess.loaded"; then
		report "nova:session" FAIL "$(diff "$work/sess.straight" "$work/sess.loaded" | short)"
	elif cmp -s "$work/sess.straight" "$work/sess.shifted"; then
		report "nova:session" FAIL "a state loaded on the wrong frame also matched: the check cannot fail"
	else
		report "nova:session" PASS "saved at $half by one process, loaded by another: the same machine at the end"
	fi
fi

# ---------------------------------------------------------------- virtual time
# The host stops for 300 ms half way, in both flavors; the machine does not
# notice. The NES reads no clock and the frame limiter is built out, so this
# proves nothing Mesen does between frames reads the host's time. The native
# run is the one with teeth: its clock is the host's, where the sandbox's is
# virtual and would hide a clock read.
"$rn" "$wd" "${args[@]}" --stall 1500 300 2>/dev/null | digests > "$work/stall.nat"
rw "$wd" "${args[@]}" --stall 1500 300 2>/dev/null | digests > "$work/stall.box"
if ! cmp -s "$work/nova.nat" "$work/stall.nat"; then
	report "time:stall" FAIL "native: $(diff "$work/nova.nat" "$work/stall.nat" | short)"
elif ! cmp -s "$work/nova.box" "$work/stall.box"; then
	report "time:stall" FAIL "sandbox: $(diff "$work/nova.box" "$work/stall.box" | short)"
else
	report "time:stall" PASS "a 300 ms stop of the host at frame 1500 changes nothing, native or sandboxed"
fi

# ---------------------------------------------------------------- the system bus
# A tool reading the whole 64 KiB bus after every frame (RAM Search, a hex
# editor) must leave the machine as it was: the run with the reads is the
# run without them. The bus reads the same in both flavors, and its first
# 2 KiB is the RAM domain.
rw "$wd" "${args[@]}" --look 2>/dev/null > "$work/look.raw"
"$rn" "$wd" "${args[@]}" --look 2>/dev/null > "$work/look.nat"
digests < "$work/look.raw" > "$work/look.box"
if ! cmp -s "$work/nova.box" "$work/look.box"; then
	report "bus:look" FAIL "reading the bus changed the machine: $(diff "$work/nova.box" "$work/look.box" | short)"
elif [ "$(grep '^busHash' "$work/look.raw")" != "$(grep '^busHash' "$work/look.nat")" ] || [ -z "$(grep '^busHash' "$work/look.raw")" ]; then
	report "bus:look" FAIL "the bus reads differently in the two flavors"
elif ! grep -q '^busIsRam=1' "$work/look.raw"; then
	report "bus:look" FAIL "the bus's first 2 KiB is not the RAM domain"
else
	report "bus:look" PASS "the whole bus read after each of 3000 frames: same machine, same bus in both flavors, \$0000-\$07FF is RAM"
fi

# The PPU bus (bus 1): the picture chip's 16 KiB. Read whole after every
# frame it must leave the machine as it was too, and read the same in both
# flavors.
rw "$wd" "${args[@]}" --look-ppu 2>/dev/null > "$work/lookppu.raw"
"$rn" "$wd" "${args[@]}" --look-ppu 2>/dev/null > "$work/lookppu.nat"
digests < "$work/lookppu.raw" > "$work/lookppu.box"
if ! cmp -s "$work/nova.box" "$work/lookppu.box"; then
	report "bus:ppu-look" FAIL "reading the PPU bus changed the machine: $(diff "$work/nova.box" "$work/lookppu.box" | short)"
elif [ "$(grep '^ppuBusHash' "$work/lookppu.raw")" != "$(grep '^ppuBusHash' "$work/lookppu.nat")" ] || [ -z "$(grep '^ppuBusHash' "$work/lookppu.raw")" ]; then
	report "bus:ppu-look" FAIL "the PPU bus reads differently in the two flavors"
else
	report "bus:ppu-look" PASS "the whole PPU bus read after each of 3000 frames: same machine, same bus in both flavors"
fi
# What the PPU bus holds, on the input test cartridge (CHR RAM, its picture
# in nametable 0): $0000-$1FFF is the CHR RAM domain, $2000-$23FF the first
# KiB of CIRAM, $3F00-$3F1F the palette with its four mirrored entries.
pw="$(workdir bus.ppu input-test.nes '{}')"
for dom in "CHR RAM" CIRAM PALRAM; do "$rn" "$pw" --frames 60 --dump-domain "$dom" "$work/ppu.$dom" > /dev/null 2>&1; done
"$rn" "$pw" --frames 60 --dump-bus 1 "$work/ppu.nat" > /dev/null 2>&1
rw "$pw" --frames 60 --dump-bus 1 "$work/ppu.box" > /dev/null 2>&1
ppu="$(python3 -I - "$work" <<'PYPPU'
import sys
w = sys.argv[1]
bus = open(w + "/ppu.nat", "rb").read()
chr_ram = open(w + "/ppu.CHR RAM", "rb").read()
ciram = open(w + "/ppu.CIRAM", "rb").read()
pal = open(w + "/ppu.PALRAM", "rb").read()
bad = []
if len(bus) != 0x4000: bad.append("the bus is %d bytes" % len(bus))
if bus[:0x2000] != chr_ram[:0x2000]: bad.append("$0000-$1FFF is not CHR RAM")
if bus[0x2000:0x2400] != ciram[:0x400]: bad.append("$2000-$23FF is not CIRAM")
mirror = lambda i: i & ~0x10 if i in (0x10, 0x14, 0x18, 0x1C) else i
if any(bus[0x3F00 + i] != pal[mirror(i)] for i in range(32)): bad.append("$3F00-$3F1F is not PALRAM")
if bus[0x2000:0x2400].count(1) != 480: bad.append("nametable 0 does not hold the cartridge's 480 white tiles")
print("; ".join(bad) if bad else "ok")
PYPPU
)"
if [ ! -s "$work/ppu.box" ] || ! cmp -s "$work/ppu.nat" "$work/ppu.box"; then
	report "bus:ppu" FAIL "the PPU bus differs between the two flavors"
elif [ "$ppu" != ok ]; then
	report "bus:ppu" FAIL "$ppu"
else
	report "bus:ppu" PASS "\$0000-\$1FFF is CHR RAM, \$2000-\$23FF CIRAM (480 white tiles), \$3F00-\$3F1F the palette; native == sandbox"
fi

# ---------------------------------------------------------------- the EPSM
# The same program with and without the EPSM header: only the EPSM one makes
# a sound, and only in it does the chip's timer reach the CPU (the program's
# IRQ handler counts the chip's IRQs in RAM $02; the APU's IRQs are off).
we="$work/epsm"
wa="$(workdir epsm-absent epsm-absent.nes)"
"$rn" "$we" --frames 600 --exercise --audio-out "$work/epsm.pcm" --dump-domain RAM "$work/ep.ram" 2>"$work/ep.err" | digests > "$work/ep.nat"
rw "$we" --frames 600 --exercise 2>"$work/ep.box.err" | digests > "$work/ep.box"
"$rn" "$wa" --frames 600 --exercise --audio-out "$work/absent.pcm" --dump-domain RAM "$work/ea.ram" 2>"$work/ea.err" | digests > "$work/ea.nat"
rw "$wa" --frames 600 --exercise 2>"$work/ea.box.err" | digests > "$work/ea.box"
loud() { python3 -I "$here/tests/audio-stats.py" "$1" | sed -n 's/.* rms=\([0-9.]*\).*/\1/p'; }
irqs() { od -An -tu1 -j2 -N1 "$1" | tr -d ' '; }
rms_p="$(loud "$work/epsm.pcm")"
rms_a="$(loud "$work/absent.pcm")"
irq_p="$(irqs "$work/ep.ram")"
irq_a="$(irqs "$work/ea.ram")"
if ! grep -q '^\[mesen\] EPSM present' "$work/ep.err" || ! grep -q '^\[mesen\] EPSM present' "$work/ep.box.err"; then
	report "epsm:present" FAIL "the EPSM header did not plug the EPSM in, in both flavors"
elif ! grep -q '^\[mesen\] EPSM absent' "$work/ea.err" || ! grep -q '^\[mesen\] EPSM absent' "$work/ea.box.err"; then
	report "epsm:present" FAIL "a plain header plugged the EPSM in"
elif ! cmp -s "$work/ea.nat" "$work/ea.box"; then
	report "epsm:present" FAIL "without the EPSM, native and sandbox differ"
elif ! awk -v a="${rms_a:-x}" -v p="${rms_p:-0}" 'BEGIN { exit !(a == 0 && p > 1000) }'; then
	report "epsm:present" FAIL "sound RMS with the EPSM $rms_p, without $rms_a"
elif [ "${irq_a:-x}" != 0 ] || [ "${irq_p:-0}" -lt 1 ]; then
	report "epsm:present" FAIL "the chip's timer IRQs counted: $irq_p with the EPSM, $irq_a without"
else
	report "epsm:present" PASS "the EPSM header plays FM and SSG (RMS $rms_p, silent without); its timer raised $irq_p IRQs (0 without)"
fi

# The EPSM's other way in, through $4016 (OUT1's edges): the program writes
# SSG channel B that way. The control is the same program with OUT1 held
# low, which never reaches the chip: the sound must differ, the machine not.
w4="$(workdir epsm-no4016 epsm-no4016.nes)"
"$rn" "$w4" --frames 600 --exercise 2>/dev/null | digests > "$work/e4.nat"
rw "$w4" --frames 600 --exercise 2>/dev/null | digests > "$work/e4.box"
if ! cmp -s "$work/e4.nat" "$work/e4.box"; then
	report "epsm:4016" FAIL "native and sandbox differ"
elif [ "$(grep '^audioHash' "$work/e4.box")" = "$(grep '^audioHash' "$work/ep.box")" ]; then
	report "epsm:4016" FAIL "the writes through \$4016 changed nothing: they did not reach the chip"
elif [ "$(grep '^domain\[RAM\]' "$work/e4.box")" != "$(grep '^domain\[RAM\]' "$work/ep.box")" ]; then
	report "epsm:4016" FAIL "OUT1 held low changed the machine, not only the sound"
else
	report "epsm:4016" PASS "SSG channel B written through \$4016 sounds; with OUT1 held low it does not"
fi

# The rhythm ROM: a made-up 8 KiB file (the real one is Yamaha's and the user
# brings it) must reach the chip - the sound changes - and both flavors must
# agree. A file of the wrong size is refused by Mesen, so it must leave the
# sound as with no file at all: the check can fail.
wf="$(workdir epsm-fw epsm-test.nes)"
python3 -I - "$wf/ymf288_adpcm_rom.bin" 8192 <<'PYROM'
import random, sys
r = random.Random(410)
open(sys.argv[1], "wb").write(bytes(r.randrange(256) for _ in range(int(sys.argv[2]))))
PYROM
"$rn" "$wf" --frames 600 --exercise 2>/dev/null | digests > "$work/fw.nat"
rw "$wf" --frames 600 --exercise 2>/dev/null | digests > "$work/fw.box"
python3 -I - "$wf/ymf288_adpcm_rom.bin" 4096 <<'PYROM'
import random, sys
r = random.Random(410)
open(sys.argv[1], "wb").write(bytes(r.randrange(256) for _ in range(int(sys.argv[2]))))
PYROM
rw "$wf" --frames 600 --exercise 2>/dev/null | digests > "$work/fw.short"
a_none="$(grep '^audioHash' "$work/ep.box")"
if ! cmp -s "$work/fw.nat" "$work/fw.box"; then
	report "epsm:firmware" FAIL "with the rhythm ROM, native and sandbox differ"
elif [ "$(grep '^audioHash' "$work/fw.box")" = "$a_none" ]; then
	report "epsm:firmware" FAIL "the rhythm ROM changed nothing: it did not reach the chip"
elif [ "$(grep '^audioHash' "$work/fw.short")" != "$a_none" ]; then
	report "epsm:firmware" FAIL "a 4 KiB file was taken as the rhythm ROM"
else
	report "epsm:firmware" PASS "an 8 KiB rhythm ROM reaches the drums in both flavors; a 4 KiB file is refused"
fi

# ---------------------------------------------------------------- settings
setting_leg() { # tag settings baseline-settings rom frames extra-args...
	# the result must match its native reference and differ from the baseline's
	local tag="$1" settings="$2" base="$3" rom="$4" frames="$5"
	shift 5
	local wd
	wd="$(workdir "set.$tag" "$rom" "$settings")"
	"$rn" "$wd" --frames "$frames" "$@" 2>/dev/null | digests > "$work/s.nat"
	rw "$wd" --frames "$frames" "$@" 2>/dev/null | digests > "$work/s.box"
	printf '%s' "$base" > "$wd/settings"
	rw "$wd" --frames "$frames" "$@" 2>/dev/null | digests > "$work/s.base"
	if [ ! -s "$work/s.box" ]; then
		report "settings:$tag" FAIL "the sandbox reported nothing"
	elif ! cmp -s "$work/s.nat" "$work/s.box"; then
		report "settings:$tag" FAIL "native and sandbox differ: $(diff "$work/s.nat" "$work/s.box" | short)"
	elif cmp -s "$work/s.box" "$work/s.base"; then
		report "settings:$tag" FAIL "$settings built the machine $base builds"
	else
		report "settings:$tag" PASS "$settings is another machine than $base; native == sandbox"
	fi
}
setting_leg port1 '{"port1":"none"}' '{}' sprilo.nes 600 --exercise
setting_leg region '{"region":"pal"}' '{}' sprilo.nes 300
setting_leg ramOnes '{"ramPowerOnState":"ones"}' '{}' sprilo.nes 1
setting_leg ramRandom '{"ramPowerOnState":"random"}' '{"ramPowerOnState":"ones"}' sprilo.nes 1
setting_leg seed '{"ramPowerOnState":"random","randomSeed":7}' '{"ramPowerOnState":"random"}' sprilo.nes 1
wd="$(workdir set.pal sprilo.nes '{"region":"pal"}')"
v="$(rw "$wd" --frames 2 2>/dev/null | sed -n 's/^vsync=//p')"
if [ "$v" = "322445/6448" ]; then
	report "settings:region-rate" PASS "region=pal runs at 322445/6448 frames a second"
else
	report "settings:region-rate" FAIL "region=pal reported vsync $v"
fi

# ---------------------------------------------------------------- save data
wd="$work/nova"
mkdir -p "$work/sd.nat" "$work/sd.box"
"$rn" "$wd" "${args[@]}" --savedata-out "$work/sd.nat" 2>/dev/null | grep '^savedataFiles' > "$work/sd.n"
rw "$wd" "${args[@]}" --savedata-out "$work/sd.box" 2>/dev/null | grep '^savedataFiles' > "$work/sd.b"
if [ "$(cat "$work/sd.b")" != "savedataFiles=1" ]; then
	report "savedata:export" FAIL "Nova's battery RAM was not offered ($(cat "$work/sd.b"))"
elif diff -r "$work/sd.nat" "$work/sd.box" > /dev/null; then
	report "savedata:export" PASS "battery.sav, $(stat -c %s "$work/sd.box/battery.sav") bytes, native == sandbox"
else
	report "savedata:export" FAIL "the exported files differ"
fi

# A project's saved game is what the cartridge starts with: the battery RAM
# Nova saved, given back as the savedata slot, is the battery RAM on the
# first frame, in both flavors. A cartridge with no battery refuses one.
wi="$work/sd.import"
rm -rf "$wi" && mkdir -p "$wi"
cp "$root/tests/roms/nova.nes" "$work/sd.box/battery.sav" "$wi/"
printf '{"rom":["nova.nes"],"savedata":["battery.sav"]}' > "$wi/slots"
"$rn" "$wi" --frames 1 --dump-domain "Battery RAM" "$work/sdi.nat" > /dev/null 2>&1
rw "$wi" --frames 1 --dump-domain "Battery RAM" "$work/sdi.box" > /dev/null 2>&1
rw "$work/nova" --frames 1 --dump-domain "Battery RAM" "$work/sdi.fresh" > /dev/null 2>&1
if cmp -s "$work/sdi.nat" "$wi/battery.sav" && cmp -s "$work/sdi.box" "$wi/battery.sav" && ! cmp -s "$work/sdi.fresh" "$wi/battery.sav"; then
	report "savedata:import" PASS "the saved game is the battery RAM on frame 1, native and sandboxed; a fresh cartridge's is not"
else
	report "savedata:import" FAIL "the battery RAM on frame 1 is not the saved game given"
fi
wn="$(workdir sd.nobattery epsm-test.nes)"
cp "$work/sd.box/battery.sav" "$wn/"
printf '{"rom":["epsm-test.nes"],"savedata":["battery.sav"]}' > "$wn/slots"
"$rn" "$wn" --frames 1 > /dev/null 2> "$work/nb.nat"
rw "$wn" --frames 1 > /dev/null 2> "$work/nb.box"
if grep -q 'Init failed: error.no_battery' "$work/nb.nat" && grep -q 'Init failed: error.no_battery' "$work/nb.box"; then
	report "savedata:no-battery" PASS "a cartridge with no battery refuses a saved game, in both flavors"
else
	report "savedata:no-battery" FAIL "native: $(grep -m1 Init "$work/nb.nat"); sandbox: $(grep -m1 Init "$work/nb.box")"
fi

# A power cycle keeps what the game saved, as the console's battery does:
# Power pressed after Nova's schedule, and two frames later the battery RAM
# is the one before it. (Two: Nova's start-up writes into that RAM from the
# fourth frame on.) The same schedule without Power is the control: its RAM
# must differ, or Power did nothing.
cp "$root/tests/inputs/nova.inputs" "$work/power.inputs"
cp "$root/tests/inputs/nova.inputs" "$work/nopower.inputs"
printf '|P.|........|\n|..|........|\n|..|........|\n' >> "$work/power.inputs"
printf '|..|........|\n|..|........|\n|..|........|\n' >> "$work/nopower.inputs"
"$rn" "$work/nova" --inputs "$work/power.inputs" --dump-domain "Battery RAM" "$work/pc.nat" > /dev/null 2>&1
rw "$work/nova" --inputs "$work/power.inputs" --dump-domain "Battery RAM" "$work/pc.box" 2>/dev/null | digests > "$work/pc.box.txt"
rw "$work/nova" --inputs "$work/nopower.inputs" --dump-domain "Battery RAM" "$work/pc.before" 2>/dev/null | digests > "$work/pc.before.txt"
if ! cmp -s "$work/pc.nat" "$work/pc.box"; then
	report "savedata:power-cycle" FAIL "after the power cycle, native and sandbox differ"
elif [ "$(grep '^domain\[RAM\]' "$work/pc.box.txt")" = "$(grep '^domain\[RAM\]' "$work/pc.before.txt")" ]; then
	report "savedata:power-cycle" FAIL "Power did nothing: the RAM is the run's without it"
elif ! cmp -s "$work/pc.box" "$work/pc.before"; then
	report "savedata:power-cycle" FAIL "the power cycle lost what the game saved"
else
	report "savedata:power-cycle" PASS "Power restarts the console and the battery RAM survives it"
fi

# ---------------------------------------------------------------- input devices
# The Four Score, the Zapper and the Arkanoid controller, and the Famicom
# expansion port's Zapper, Arkanoid controller and four-player adapter, on
# this repository's input test cartridge (tests/input-test), which keeps what it
# reads from both ports in its RAM. Each device's schedule moves every one
# of its controls (waterbox/tests/input-devices.py). It must give the same
# machine natively, sandboxed, and sandboxed with a save and a load around
# every frame; the RAM must show the schedule's last frame; and with a plain
# pad in the ports instead the cartridge must not see it.
dev="$here/tests/input-devices.py"
device_leg() { # device settings
	local d="$1" settings="$2" wd
	wd="$(workdir "dev.$d" input-test.nes "$settings")"
	python3 -I "$dev" schedule "$d" "$work/$d.inputs"
	"$rn" "$wd" --frames 240 --inputs "$work/$d.inputs" --dump-domain RAM "$work/$d.nat.ram" 2>/dev/null | digests > "$work/$d.nat"
	rw "$wd" --frames 240 --inputs "$work/$d.inputs" 2>/dev/null | digests > "$work/$d.box"
	rw "$wd" --frames 240 --inputs "$work/$d.inputs" --rerecord 2>/dev/null | digests > "$work/$d.rr"
	local seen plain
	seen="$(python3 -I "$dev" check "$d" "$work/$d.inputs" "$work/$d.nat.ram")"
	local seen_ok=$?
	printf '{}' > "$wd/settings"
	"$rn" "$wd" --frames 240 --inputs "$work/$d.inputs" --dump-domain RAM "$work/$d.plain.ram" > /dev/null 2>&1
	plain="$(python3 -I "$dev" check "$d" "$work/$d.inputs" "$work/$d.plain.ram")"
	local plain_ok=$?
	if [ ! -s "$work/$d.box" ] || ! cmp -s "$work/$d.nat" "$work/$d.box"; then
		report "dev:$d" FAIL "native and sandbox differ: $(diff "$work/$d.nat" "$work/$d.box" | short)"
	elif ! cmp -s "$work/$d.box" "$work/$d.rr"; then
		report "dev:$d" FAIL "a save and a load around each frame changed the machine"
	elif [ "$seen_ok" != 0 ]; then
		report "dev:$d" FAIL "$settings: $seen"
	elif [ "$plain_ok" = 0 ]; then
		report "dev:$d" FAIL "with a plain pad the cartridge read the same: $plain"
	else
		report "dev:$d" PASS "$settings: $seen; native == sandbox == saved and loaded each frame; a plain pad is not it"
	fi
}
device_leg fourScore '{"port1":"fourScore"}'
device_leg zapper '{"port2":"zapper"}'
device_leg arkanoid '{"port2":"arkanoid"}'
device_leg famicomZapper '{"expansion":"famicomZapper"}'
device_leg famicomArkanoid '{"expansion":"famicomArkanoid"}'
device_leg fourPlayerAdapter '{"expansion":"fourPlayerAdapter"}'

# Where the Zapper points: the cartridge's right half is white and its left
# half black, so pointed right it sees light, sooner the higher it points,
# and pointed left it sees none. Native == sandbox at each place. The same
# for the Famicom Zapper on the expansion port, whose place is X= and Y=.
light_leg() { # name settings xkey ykey
	local name="$1" settings="$2" xk="$3" yk="$4" wd light="" lightSame=1 top bottom left
	wd="$(workdir "dev.$name" input-test.nes "$settings")"
	for xy in "50000 8000" "50000 56000" "10000 32000"; do
		set -- $xy
		for i in $(seq 60); do echo "|..|........|@$xk=$1 $yk=$2|"; done > "$work/light.inputs"
		"$rn" "$wd" --frames 60 --inputs "$work/light.inputs" --dump-domain RAM "$work/light.ram" > "$work/light.nat" 2>/dev/null
		rw "$wd" --frames 60 --inputs "$work/light.inputs" 2>/dev/null > "$work/light.box"
		cmp -s <(digests < "$work/light.nat") <(digests < "$work/light.box") || lightSame=0
		light="$light$(python3 -I "$dev" light "$work/light.ram");"
	done
	IFS=';' read -r top bottom left _ <<< "$light"
	if [ "$lightSame" != 1 ]; then
		report "dev:$name" FAIL "native and sandbox differ"
	elif [ "${top%% *}" = 1 ] && [ "${bottom%% *}" = 1 ] && [ "${left%% *}" = 0 ] && [ "${top##* }" -lt "${bottom##* }" ]; then
		report "dev:$name" PASS "light seen high on the right after ${top##* } reads, low after ${bottom##* }, never on the left; native == sandbox"
	else
		report "dev:$name" FAIL "seen/reads: right high $top, right low $bottom, left $left"
	fi
}
light_leg zapper-light '{"port2":"zapper"}' x y
light_leg famicomZapper-light '{"expansion":"famicomZapper"}' X Y

# ---------------------------------------------------------------- FamiStudio's EPSM songs
# EPSM music made by a tool other than ours: songs exported to .nes by
# FamiStudio (MIT; its sound engine drives the EPSM). The folder is given by
# MESEN_FAMISTUDIO_ROMS and every .nes in it is run; nothing here needs it,
# and without it the checks say SKIP. For each cartridge, 1800 frames
# (30 seconds) with the pad exercise:
#   - native == sandbox (picture, sound, lag, every memory domain), and a
#     save and a load around every frame change nothing;
#   - a state saved at frame 900 by one process and loaded by another ends
#     on the straight run's machine;
#   - the EPSM plays: the same cartridge with the EPSM taken out of its
#     header (console type 0, no extended type) sounds different, and the
#     difference - what the EPSM played - is loud (RMS 300 or more).
fsdir="${MESEN_FAMISTUDIO_ROMS:-}"
fsroms=()
if [ -n "$fsdir" ] && [ -d "$fsdir" ]; then
	for f in "$fsdir"/*.nes; do [ -f "$f" ] && fsroms+=("$f"); done
fi
if [ "${#fsroms[@]}" = 0 ]; then
	report "famistudio:*" SKIP "3 checks a cartridge: need MESEN_FAMISTUDIO_ROMS, a folder of .nes files FamiStudio exported (not in this repository)"
else
	i=0
	for f in "${fsroms[@]}"; do
		i=$((i + 1))
		tag="fs$i"
		label="famistudio:$(basename "$f" .nes)"
		wd="$work/$tag" && rm -rf "$wd" && mkdir -p "$wd" && cp "$f" "$wd/song.nes" && printf '{"rom":["song.nes"]}' > "$wd/slots"
		fargs=(--frames 1800 --exercise)
		"$rn" "$wd" "${fargs[@]}" --audio-out "$work/$tag.nat.audio" 2>"$work/$tag.nat.err" | digests > "$work/$tag.nat"
		rw "$wd" "${fargs[@]}" 2>/dev/null > "$work/$tag.raw"
		digests < "$work/$tag.raw" > "$work/$tag.box"
		rw "$wd" "${fargs[@]}" --rerecord 2>/dev/null | digests > "$work/$tag.rr"
		if [ "$(sed -n 's/^frames=//p' "$work/$tag.box")" != 1800 ]; then
			report "$label:equivalence" FAIL "the sandbox did not run 1800 frames: $(grep -v '^\[mesen\]' "$work/$tag.nat.err" | head -1)"
		elif ! cmp -s "$work/$tag.nat" "$work/$tag.box"; then
			report "$label:equivalence" FAIL "native and sandbox differ: $(diff "$work/$tag.nat" "$work/$tag.box" | short)"
		elif ! cmp -s "$work/$tag.box" "$work/$tag.rr"; then
			report "$label:equivalence" FAIL "a save and a load around each frame changed the machine"
		else
			report "$label:equivalence" PASS "1800 frames, native == sandbox == saved and loaded each frame (picture, sound, lag, every domain)"
		fi

		finalDigests < "$work/$tag.raw" > "$work/$tag.straight"
		rw "$wd" "${fargs[@]}" --save-at 900 "$work/$tag.state" > "$work/$tag.save" 2>/dev/null
		rw "$wd" "${fargs[@]}" --load-at 900 "$work/$tag.state" 2>/dev/null | finalDigests > "$work/$tag.loaded"
		if ! grep -q '^savedAt=900' "$work/$tag.save"; then
			report "$label:session" FAIL "no state was saved at frame 900"
		elif [ -s "$work/$tag.loaded" ] && cmp -s "$work/$tag.straight" "$work/$tag.loaded"; then
			report "$label:session" PASS "saved at 900 by one process, loaded by another: the same machine at frame 1800"
		else
			report "$label:session" FAIL "$(diff "$work/$tag.straight" "$work/$tag.loaded" | short)"
		fi

		wdn="$work/$tag.noepsm" && rm -rf "$wdn" && mkdir -p "$wdn" && printf '{"rom":["song.nes"]}' > "$wdn/slots"
		python3 -I - "$f" "$wdn/song.nes" <<'PYHDR'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[7] &= 0xFC   # console type 0: a plain NES
d[13] &= 0xF0  # no extended console type
open(sys.argv[2], "wb").write(d)
PYHDR
		"$rn" "$wdn" "${fargs[@]}" --audio-out "$work/$tag.noepsm.audio" > /dev/null 2>"$work/$tag.noepsm.err"
		snd="$(python3 -I "$here/tests/audio-diff.py" "$work/$tag.nat.audio" "$work/$tag.noepsm.audio")"
		diffrms="${snd##*difference=}"
		if ! grep -q 'EPSM present' "$work/$tag.nat.err" || ! grep -q 'EPSM absent' "$work/$tag.noepsm.err"; then
			report "$label:epsm" FAIL "the header did not plug the EPSM in, or taking it out did not unplug it"
		elif [ "${diffrms%.*}" -ge 300 ]; then
			report "$label:epsm" PASS "the EPSM plays: $snd (with the EPSM, without, and what it added)"
		else
			report "$label:epsm" FAIL "the EPSM added nothing loud: $snd"
		fi
	done
fi

# ---------------------------------------------------------------- the build
# No network code in the guest (patches/0006, user-decided 2026-10-31).
if nn="$("$here/tests/check-no-network.sh" "$gst/core.wbx" 2>&1)"; then
	report "build:no-network" PASS "$nn"
else
	report "build:no-network" FAIL "$(printf '%s' "$nn" | short)"
fi

# ---------------------------------------------------------------- the texts
# Proper nouns are never translated or bent (owner, 2026-10-31): Mesen, NES,
# EPSM, YMF288 and the rest stay as written in all 26 language tables.
if nm_out="$(python3 -I "$here/tests/check-names.py" "$here/languages" 2>&1)"; then
	report "texts:names" PASS "$(printf '%s' "$nm_out" | tail -1)"
else
	report "texts:names" FAIL "$(printf '%s' "$nm_out" | grep -v 'bent or missing names in' | short)"
fi
# Chimera's own checks of a core's texts, when a Chimera checkout is given:
# every key named and every name a key, and Chimera's names unbent.
ct="${CHIMERA_ROOT:-}/tools/check-core-texts.py"
pn="${CHIMERA_ROOT:-}/tools/check-proper-nouns.py"
if [ -n "${CHIMERA_ROOT:-}" ] && [ -f "$ct" ] && [ -f "$pn" ]; then
	if ct_out="$(python3 -I "$ct" "$root" 2>&1)" && pn_out="$(python3 -I "$pn" "$here" 2>&1)"; then
		report "texts:chimera" PASS "$(printf '%s' "$ct_out" | tail -1); $(printf '%s' "$pn_out" | tail -1)"
	else
		report "texts:chimera" FAIL "$(printf '%s %s' "${ct_out:-}" "${pn_out:-}" | short)"
	fi
else
	report "texts:chimera" SKIP "needs CHIMERA_ROOT with tools/check-core-texts.py and tools/check-proper-nouns.py"
fi

# ---------------------------------------------------------------- Chimera's engine
# Each read of the controls reaches Chimera as it happens, so a Lua script's
# event.oninputpoll runs there (chimera#344): every frame the game read them
# has at least one, and counting them moves nothing.
runner="${CHIMERA_ROOT:-}/build/dll/chimera-run"
package="${MESEN_PACKAGE:-$root/build/Cores/mesen.chimeraCore}"
if [ -n "${CHIMERA_ROOT:-}" ] && [ -x "$runner" ] && [ -f "$package" ]; then
	cart="$root/tests/roms/sprilo.nes"
	"$runner" --new-project "$work/none.chimeraProject" "$package" "$cart" > "$work/none.make.log" 2>&1
	"$runner" --project "$work/none.chimeraProject" "$package" --files "$(dirname "$cart")" \
		--frames 300 --record "$work/idle.txt" > "$work/idle.log" 2>&1
	"$runner" --new-project "$work/idle.chimeraProject" "$package" "$cart" "$work/idle.txt" > "$work/idle.make.log" 2>&1
	"$runner" --project "$work/idle.chimeraProject" "$package" --files "$(dirname "$cart")" \
		--dump "RAM=$work/plain.ram" > "$work/plain.log" 2>&1
	"$runner" --project "$work/idle.chimeraProject" "$package" --files "$(dirname "$cart")" --count-input-polls \
		--dump "RAM=$work/polls.ram" --meta "$work/polls.meta" > "$work/polls.log" 2>&1
	polls=$(sed -n 's/^inputPolls=//p' "$work/polls.meta" 2> /dev/null)
	lags=$(sed -n 's/^lagFrames=//p' "$work/polls.meta" 2> /dev/null)
	frames=$(sed -n 's/^frames=//p' "$work/polls.meta" 2> /dev/null)
	if [ "${polls:-none}" != none ] && [ "${frames:-0}" = 300 ] && [ "${lags:-300}" -lt 300 ] \
		&& [ "${polls:-0}" -ge $(( 300 - ${lags:-300} )) ] && [ -s "$work/plain.ram" ] && cmp -s "$work/plain.ram" "$work/polls.ram"; then
		report "engine:input-polls" PASS "$polls reads of the pads in 300 frames, $lags lag frames; RAM is the run's without counting"
	else
		report "engine:input-polls" FAIL "inputPolls=${polls:-missing} frames=${frames:-?} lagFrames=${lags:-?}, or counting moved RAM; the runner said: $(tail -1 "$work/polls.log" 2> /dev/null)"
	fi

	# What the core suggests for a game (the new-project window asks before
	# the game boots): the EPSM's drums for a cartridge whose header has the
	# EPSM, nothing for one without.
	"$runner" --new-project "$work/sg.epsm.chimeraProject" "$package" "$root/tests/roms/epsm-test.nes" > /dev/null 2>&1
	"$runner" --new-project "$work/sg.nova.chimeraProject" "$package" "$root/tests/roms/nova.nes" > /dev/null 2>&1
	sg_e="$("$runner" --project "$work/sg.epsm.chimeraProject" "$package" --files "$root/tests/roms" --suggest 2>&1 | tail -1)"
	sg_n="$("$runner" --project "$work/sg.nova.chimeraProject" "$package" --files "$root/tests/roms" --suggest 2>&1 | tail -1)"
	if printf '%s' "$sg_e" | grep -q '"epsmDrums": "on"' && printf '%s' "$sg_n" | grep -q '"values": {}'; then
		report "engine:suggest" PASS "EPSM Drums suggested for the EPSM cartridge, nothing for Nova"
	else
		report "engine:suggest" FAIL "EPSM cartridge: $sg_e / Nova: $sg_n"
	fi

	# The rhythm ROM through Chimera: a project with EPSM Drums on, given the
	# firmware, mounts it where Mesen looks; given none, the core says the
	# drums are silent.
	python3 -I - "$work/rhythm.bin" <<'PYROM'
import random, sys
r = random.Random(410)
open(sys.argv[1], "wb").write(bytes(r.randrange(256) for _ in range(8192)))
PYROM
	"$runner" --new-project "$work/fw.chimeraProject" "$package" "$root/tests/roms/epsm-test.nes" \
		--settings '{"epsmDrums":"on"}' --firmware "ymf288_adpcm_rom.bin=$work/rhythm.bin" > /dev/null 2>&1
	"$runner" --project "$work/fw.chimeraProject" "$package" --files "$root/tests/roms" \
		--firmware "ymf288_adpcm_rom.bin=$work/rhythm.bin" --frames 30 --record "$work/fw.txt" > "$work/fw.log" 2>&1
	"$runner" --project "$work/fw.chimeraProject" "$package" --files "$root/tests/roms" \
		--frames 30 --record "$work/fw2.txt" > "$work/fw2.log" 2>&1
	if grep -q 'EPSM rhythm ROM loaded' "$work/fw.log" && grep -q 'EPSM rhythm ROM missing' "$work/fw2.log"; then
		report "engine:epsm-firmware" PASS "the rhythm ROM given to Chimera reaches Mesen; without it the core says the drums are silent"
	else
		report "engine:epsm-firmware" FAIL "with the file: $(grep -m1 'rhythm\|chimera-run' "$work/fw.log"); without: $(grep -m1 'rhythm\|chimera-run' "$work/fw2.log")"
	fi

	# A movie through Chimera's engine: Nova's schedule written as a Chimera
	# movie (|console|pad 1|pad 2|, each pad's letters in the declared order
	# A B s S U D L R), played by chimera-run in a project, ends on the RAM
	# of the native reference's run of the same schedule.
	python3 -I - "$root/tests/inputs/nova.inputs" "$work/nova.movie.txt" <<'PYMOV'
import sys
out = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    console, pad = line.split("|")[1:3]
    held = {c for c in pad if c != "."}  # U D L R S s B A
    p1 = "".join(c if c in held else "." for c in "ABsSUDLR")
    out.append("|" + console + "|" + p1 + "|........|")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PYMOV
	"$rn" "$work/nova" "${args[@]}" --dump-domain RAM "$work/mv.native.ram" > /dev/null 2>&1
	"$runner" --new-project "$work/mv.chimeraProject" "$package" "$root/tests/roms/nova.nes" "$work/nova.movie.txt" > "$work/mv.make.log" 2>&1
	"$runner" --project "$work/mv.chimeraProject" "$package" --files "$root/tests/roms" \
		--dump "RAM=$work/mv.engine.ram" --dump "System Bus@0+800=$work/mv.engine.bus" \
		--dump "CIRAM=$work/mv.engine.ciram" --dump "PPU Bus@2000+400=$work/mv.engine.ppu" --meta "$work/mv.meta" > "$work/mv.log" 2>&1
	mvframes=$(sed -n 's/^frames=//p' "$work/mv.meta" 2> /dev/null)
	if [ "${mvframes:-0}" != 3000 ]; then
		report "engine:movie" FAIL "the movie played ${mvframes:-no} frames, not 3000: $(tail -1 "$work/mv.log")"
	elif ! cmp -s "$work/mv.engine.ram" "$work/mv.engine.bus"; then
		report "engine:movie" FAIL "Chimera's view of the system bus at \$0000-\$07FF is not the RAM domain"
	elif ! cmp -s -n 1024 "$work/mv.engine.ciram" "$work/mv.engine.ppu" || [ ! -s "$work/mv.engine.ppu" ]; then
		report "engine:movie" FAIL "Chimera's view of the PPU bus at \$2000-\$23FF is not the first KiB of CIRAM"
	elif cmp -s "$work/mv.native.ram" "$work/mv.engine.ram"; then
		report "engine:movie" PASS "Nova's 3000-frame schedule as a Chimera movie ends on the native reference's RAM, which the system bus shows too; the PPU bus shows CIRAM"
	else
		report "engine:movie" FAIL "the movie through Chimera ends on another RAM than the native run"
	fi

	# The input devices through Chimera: each device's schedule written as a
	# Chimera movie with only the controls the machine has (the core's
	# IsButtonActive and IsAxisActive), played in a project whose ports hold
	# the device, ends on the native reference's RAM.
	devfail=""
	for ds in 'fourScore {"port1":"fourScore"}' 'zapper {"port2":"zapper"}' 'arkanoid {"port2":"arkanoid"}' \
		'famicomZapper {"expansion":"famicomZapper"}' 'famicomArkanoid {"expansion":"famicomArkanoid"}' \
		'fourPlayerAdapter {"expansion":"fourPlayerAdapter"}'; do
		d="${ds%% *}"
		python3 -I "$dev" movie "$d" "$work/$d.inputs" "$work/$d.movie.txt"
		"$runner" --new-project "$work/dv.$d.chimeraProject" "$package" "$root/tests/roms/input-test.nes" "$work/$d.movie.txt" \
			--settings "${ds#* }" > "$work/dv.$d.make.log" 2>&1
		"$runner" --project "$work/dv.$d.chimeraProject" "$package" --files "$root/tests/roms" \
			--dump "RAM=$work/dv.$d.ram" --meta "$work/dv.$d.meta" > "$work/dv.$d.log" 2>&1
		f=$(sed -n 's/^frames=//p' "$work/dv.$d.meta" 2> /dev/null)
		if [ "${f:-0}" != 240 ]; then
			devfail="$devfail $d: ${f:-no} frames ($(tail -1 "$work/dv.$d.log"));"
		elif ! cmp -s "$work/dv.$d.ram" "$work/$d.nat.ram"; then
			devfail="$devfail $d: another RAM than native;"
		fi
	done
	if [ -z "$devfail" ]; then
		report "engine:devices" PASS "the six devices' schedules (Four Score, Zapper, Arkanoid; the expansion port's Zapper, Arkanoid, four-player adapter) as Chimera movies end on the native reference's RAM"
	else
		report "engine:devices" FAIL "$devfail"
	fi

	# FamiStudio's EPSM songs through Chimera (only with MESEN_FAMISTUDIO_ROMS):
	# a 900-frame schedule (P1 Right, Left, A and B held now and then, which
	# FamiStudio's player reads) written as a Chimera movie, made into a
	# project by one chimera-run and replayed by another, ends on the native
	# reference's RAM, and the core's log says the EPSM is there. It says for
	# how many of them the buttons changed the RAM at all (FamiStudio's player
	# with one song, or none, may not notice them).
	if [ "${#fsroms[@]}" -gt 0 ]; then
		python3 -I - "$work/fs.inputs" "$work/fs.movie.txt" <<'PYFS'
import sys
inp, mov = [], []
for f in range(900):
    held = ""
    for start, b in ((120, "R"), (300, "A"), (480, "L"), (660, "B"), (780, "R")):
        if start <= f < start + 6:
            held = b
    inp.append("|..|" + "".join(c if c == held else "." for c in "UDLRSsBA") + "|")
    mov.append("|..|" + "".join(c if c == held else "." for c in "ABsSUDLR") + "|")
open(sys.argv[1], "w").write("\n".join(inp) + "\n")
open(sys.argv[2], "w").write("\n".join(mov) + "\n")
PYFS
		fsfail=""
		fsshaped=0
		i=0
		for f in "${fsroms[@]}"; do
			i=$((i + 1))
			tag="fs$i"
			"$rn" "$work/$tag" --frames 900 --inputs "$work/fs.inputs" --dump-domain RAM "$work/$tag.mv.native.ram" > /dev/null 2>&1
			"$rn" "$work/$tag" --frames 900 --dump-domain RAM "$work/$tag.mv.idle.ram" > /dev/null 2>&1
			cmp -s "$work/$tag.mv.native.ram" "$work/$tag.mv.idle.ram" || fsshaped=$((fsshaped + 1))
			"$runner" --new-project "$work/$tag.chimeraProject" "$package" "$f" "$work/fs.movie.txt" > "$work/$tag.mv.make.log" 2>&1
			"$runner" --project "$work/$tag.chimeraProject" "$package" --files "$(dirname "$f")" \
				--dump "RAM=$work/$tag.mv.engine.ram" --meta "$work/$tag.mv.meta" > "$work/$tag.mv.log" 2>&1
			n=$(sed -n 's/^frames=//p' "$work/$tag.mv.meta" 2> /dev/null)
			if [ "${n:-0}" != 900 ]; then
				fsfail="$fsfail $(basename "$f"): ${n:-no} frames ($(tail -1 "$work/$tag.mv.log"));"
			elif ! grep -q 'EPSM present' "$work/$tag.mv.log"; then
				fsfail="$fsfail $(basename "$f"): the log does not say the EPSM is there;"
			elif ! cmp -s "$work/$tag.mv.native.ram" "$work/$tag.mv.engine.ram"; then
				fsfail="$fsfail $(basename "$f"): another RAM than native;"
			fi
		done
		if [ -z "$fsfail" ]; then
			report "engine:famistudio" PASS "${#fsroms[@]} FamiStudio cartridges: a 900-frame movie replayed by chimera-run in a new process ends on the native reference's RAM, with the EPSM; the movie's buttons changed the RAM of $fsshaped of them"
		else
			report "engine:famistudio" FAIL "$fsfail"
		fi
	else
		report "engine:famistudio" SKIP "needs MESEN_FAMISTUDIO_ROMS (FamiStudio's exported songs, not in this repository)"
	fi
else
	report "engine:*" SKIP "6 checks: need CHIMERA_ROOT (with build/dll/chimera-run) and the package (MESEN_PACKAGE, default build/Cores/mesen.chimeraCore)"
fi

echo ""
echo "$ok ok, $failed failed"
[ "$failed" -gt 0 ] && exit 1
exit 0

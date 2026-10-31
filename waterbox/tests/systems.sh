# systems.sh - the checks of the package's other machines (the Super NES,
# the Game Boy and the rest), sourced by waterbox/run-gate.sh, which defines
# rn, rw, work, root, here, report, digests, turboDigests, finalDigests and
# short. The NES's checks are run-gate.sh's own.
#
# Each machine is checked on a test program this repository builds
# (tests/<system>-test), which keeps what it reads from the controllers in
# its RAM, and on the owner's games when MESEN_SYSTEMS_CONTENT names the
# folder holding them (systems/<system>/ and firmware/, as the owner keeps
# them; never in this repository). Without it those checks say SKIP.
#
# systems_core runs the checks of the core alone (native reference and
# sandbox); systems_engine the ones through Chimera's engine (chimera-run),
# called with the runner and the package.

sys_py="$here/tests/systems.py"
scontent="${MESEN_SYSTEMS_CONTENT:-}"

# a work dir holding a game as a project of the machine mounts it: the file
# under its name, the slot map ("cart"), the settings, and firmware files
# under their ids (src=id, from the owner's firmware folder or a path)
sysdir() { # tag file settings [src=id]...
	local wd="$work/sys.$1" file="$2" settings="$3"
	shift 3
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$file" "$wd/"
	python3 -I -c 'import json, sys; print(json.dumps({"cart": [sys.argv[1]]}))' "$(basename "$file")" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	local p src
	for p in "$@"; do
		src="${p%%=*}"
		[ -f "$src" ] || src="$scontent/firmware/$src"
		cp "$src" "$wd/${p##*=}"
	done
	echo "$wd"
}

# The checks every machine gets on its test program:
#   <tag>:equivalence  the schedule's run, native == sandbox (frames,
#                      picture, sound, lag, every memory domain)
#   <tag>:input        the program's RAM holds the schedule's last frame's
#                      buttons, and the run without them is another machine
#   <tag>:buttons      each button of each player, held alone at the end of
#                      a short run, is read as itself and no other
#   <tag>:savestate    a save and a load around every frame change nothing
#   <tag>:turbo        no picture for half the run: the same machine, sound
#                      and later pictures, and the first half really undrawn
#   <tag>:session      a state saved half way by one process, loaded by
#                      another, ends on the straight run's machine (and the
#                      same state loaded ten frames off does not)
#   <tag>:bus          the system bus read whole after every frame changes
#                      nothing, and reads the same in both flavors
sys_program_legs() { # tag machine rom settings players frames domain [src=id]...
	local tag="$1" machine="$2" rom="$3" settings="$4" players="$5" frames="$6" domain="$7" colframes="${COLFRAMES:-240}"
	shift 7
	local wd wire inputs need
	for need in "$@"; do
		need="${need%%=*}"
		if [ -z "$scontent" ] || [ ! -f "$scontent/firmware/$need" ]; then
			report "$tag:*" SKIP "8 checks: need $need in MESEN_SYSTEMS_CONTENT/firmware"
			return
		fi
	done
	wd="$(sysdir "$tag" "$rom" "$settings" "$@")"
	wire="$(python3 -I "$sys_py" wire "$machine")"
	inputs="$work/$tag.inputs"
	python3 -I "$sys_py" schedule "$machine" "$players" "$frames" "$inputs"
	local args=(--frames "$frames" --inputs "$inputs" --wire "$wire")
	echo "${args[*]}" > "$work/$tag.args"

	"$rn" "$wd" "${args[@]}" --dump-domain "$domain" "$work/$tag.nat.ram" 2>"$work/$tag.nat.err" | digests > "$work/$tag.nat"
	rw "$wd" "${args[@]}" --dump-domain "$domain" "$work/$tag.box.ram" 2>"$work/$tag.box.err" > "$work/$tag.raw"
	digests < "$work/$tag.raw" > "$work/$tag.box"
	if [ "$(sed -n 's/^frames=//p' "$work/$tag.box")" != "$frames" ]; then
		report "$tag:equivalence" FAIL "the sandbox did not run $frames frames: $(grep -v '^\[mesen\]' "$work/$tag.box.err" | head -1)"
		return
	fi
	if cmp -s "$work/$tag.nat" "$work/$tag.box"; then
		report "$tag:equivalence" PASS "$frames frames, native == sandbox (picture, sound, lag, every domain)"
	else
		report "$tag:equivalence" FAIL "$(diff "$work/$tag.nat" "$work/$tag.box" | short)"
	fi

	local seen
	rw "$wd" --frames "$frames" --wire "$wire" 2>/dev/null | digests > "$work/$tag.idle"
	if ! seen="$(python3 -I "$sys_py" check "$machine" "$players" "$inputs" "$work/$tag.box.ram" 2>&1)"; then
		report "$tag:input" FAIL "$seen"
	elif cmp -s "$work/$tag.box" "$work/$tag.idle"; then
		report "$tag:input" FAIL "the run without the buttons is the same machine"
	else
		report "$tag:input" PASS "$seen; the idle run is another machine"
	fi

	# every button on its own: each player's each column held alone at the
	# end of a short run reaches the program as that button and no other
	# (natively; equivalence above holds the sandbox to the native runs)
	local ncol p c bad="" nrun=0
	ncol="$(python3 -I "$sys_py" columns "$machine")"
	for p in $(seq 1 "$players"); do
		for c in $(seq 0 $((ncol - 1))); do
			python3 -I "$sys_py" column "$machine" "$colframes" "$p" "$c" "$work/$tag.col.inputs"
			"$rn" "$wd" --frames "$colframes" --inputs "$work/$tag.col.inputs" --wire "$wire" \
				--dump-domain "$domain" "$work/$tag.col.ram" > /dev/null 2>&1
			nrun=$((nrun + 1))
			if ! seen="$(python3 -I "$sys_py" check "$machine" "$players" "$work/$tag.col.inputs" "$work/$tag.col.ram" 2>&1)"; then
				bad="P$p column $c: $seen"
				break 2
			fi
		done
	done
	if [ -n "$bad" ]; then
		report "$tag:buttons" FAIL "$bad"
	else
		report "$tag:buttons" PASS "each of the $nrun buttons of $players player(s), held alone, reaches the program as itself and no other"
	fi

	if rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$tag.rr" && cmp -s "$work/$tag.box" "$work/$tag.rr"; then
		report "$tag:savestate" PASS "a save and a load around each of $frames frames change nothing"
	else
		report "$tag:savestate" FAIL "$(diff "$work/$tag.box" "$work/$tag.rr" | short)"
	fi

	turboDigests < "$work/$tag.raw" > "$work/$tag.tn"
	rw "$wd" "${args[@]}" --turbo 2>/dev/null > "$work/$tag.traw"
	turboDigests < "$work/$tag.traw" > "$work/$tag.tt"
	if ! cmp -s "$work/$tag.tn" "$work/$tag.tt"; then
		report "$tag:turbo" FAIL "$(diff "$work/$tag.tn" "$work/$tag.tt" | short)"
	elif [ "$(grep -m1 '^videoHash=' "$work/$tag.raw")" = "$(grep -m1 '^videoHash=' "$work/$tag.traw")" ]; then
		report "$tag:turbo" FAIL "the turbo run drew every frame - nothing was skipped"
	else
		report "$tag:turbo" PASS "half the frames undrawn; same machine, sound and later pictures"
	fi

	local half=$((frames / 2))
	finalDigests < "$work/$tag.raw" > "$work/$tag.straight"
	rw "$wd" "${args[@]}" --save-at "$half" "$work/$tag.state" > "$work/$tag.save" 2>/dev/null
	rw "$wd" "${args[@]}" --load-at "$half" "$work/$tag.state" 2>/dev/null | finalDigests > "$work/$tag.loaded"
	rw "$wd" "${args[@]}" --load-at $((half - 10)) "$work/$tag.state" 2>/dev/null | finalDigests > "$work/$tag.shifted"
	if ! grep -q "^savedAt=$half" "$work/$tag.save" || [ ! -s "$work/$tag.loaded" ]; then
		report "$tag:session" FAIL "no state was saved at frame $half, or the loading process reported nothing"
	elif ! cmp -s "$work/$tag.straight" "$work/$tag.loaded"; then
		report "$tag:session" FAIL "$(diff "$work/$tag.straight" "$work/$tag.loaded" | short)"
	elif cmp -s "$work/$tag.straight" "$work/$tag.shifted"; then
		report "$tag:session" FAIL "a state loaded on the wrong frame also matched: the check cannot fail"
	else
		report "$tag:session" PASS "saved at $half by one process, loaded by another: the same machine at the end"
	fi

	"$rn" "$wd" "${args[@]}" --look 2>/dev/null > "$work/$tag.look.nat"
	rw "$wd" "${args[@]}" --look 2>/dev/null > "$work/$tag.look.raw"
	digests < "$work/$tag.look.raw" > "$work/$tag.look.box"
	if ! cmp -s "$work/$tag.box" "$work/$tag.look.box"; then
		report "$tag:bus" FAIL "reading the bus changed the machine: $(diff "$work/$tag.box" "$work/$tag.look.box" | short)"
	elif [ -z "$(grep '^busHash' "$work/$tag.look.raw")" ] || [ "$(grep '^busHash' "$work/$tag.look.raw")" != "$(grep '^busHash' "$work/$tag.look.nat")" ]; then
		report "$tag:bus" FAIL "the bus reads differently in the two flavors"
	else
		report "$tag:bus" PASS "the system bus's first 64 KiB read after each of $frames frames: same machine, same bus in both flavors"
	fi
}

# A game of the owner's: the pad exercise (Start now and then) for long
# enough to reach play, native == sandbox == sandboxed with a save and a
# load around every frame, and another machine than the run with nothing
# pressed (the pad reached the game); a state crosses processes; the sound is not
# silence and the last picture is not one colour (a blank screen). SKIP when the
# game or a firmware file it needs is absent.
sys_game_leg() { # tag machine file settings frames [src=id]...
	local tag="$1" machine="$2" file="$3" settings="$4" frames="$5"
	shift 5
	local need
	for need in "$file" "$@"; do
		need="${need%%=*}"
		[ "$need" = "$file" ] || need="$scontent/firmware/$need"
		if [ -z "$scontent" ] || [ ! -f "$need" ]; then
			report "$tag" SKIP "needs $(basename "$need") in MESEN_SYSTEMS_CONTENT"
			return
		fi
	done
	local wd
	wd="$(sysdir "$tag" "$file" "$settings" "$@")"
	local args=(--frames "$frames" --exercise --wire "$(python3 -I "$sys_py" wire "$machine")" --pad "$(python3 -I "$sys_py" pad "$machine")")
	"$rn" "$wd" "${args[@]}" --audio-out "$work/$tag.pcm" --screenshot "$work/$tag.tga" 2>"$work/$tag.nat.err" | digests > "$work/$tag.nat"
	rw "$wd" "${args[@]}" 2>"$work/$tag.box.err" > "$work/$tag.raw"
	digests < "$work/$tag.raw" > "$work/$tag.box"
	rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$tag.rr"
	local half=$((frames / 2))
	finalDigests < "$work/$tag.raw" > "$work/$tag.straight"
	rw "$wd" "${args[@]}" --save-at "$half" "$work/$tag.state" > /dev/null 2>&1
	rw "$wd" "${args[@]}" --load-at "$half" "$work/$tag.state" 2>/dev/null | finalDigests > "$work/$tag.loaded"
	rw "$wd" --frames "$frames" --wire "$(python3 -I "$sys_py" wire "$machine")" 2>/dev/null | digests > "$work/$tag.idle"
	local rms colours
	rms="$(python3 -I "$here/tests/audio-stats.py" "$work/$tag.pcm" 2>/dev/null | sed -n 's/.* rms=\([0-9.]*\).*/\1/p')"
	colours="$(python3 -I "$sys_py" colours "$work/$tag.tga" 2>/dev/null)"
	if [ "$(sed -n 's/^frames=//p' "$work/$tag.box")" != "$frames" ]; then
		report "$tag" FAIL "the sandbox did not run $frames frames: $(grep -v '^\[mesen\]' "$work/$tag.box.err" | head -1)"
	elif ! cmp -s "$work/$tag.nat" "$work/$tag.box"; then
		report "$tag" FAIL "native and sandbox differ: $(diff "$work/$tag.nat" "$work/$tag.box" | short)"
	elif ! cmp -s "$work/$tag.box" "$work/$tag.rr"; then
		report "$tag" FAIL "a save and a load around each frame changed the machine"
	elif ! cmp -s "$work/$tag.straight" "$work/$tag.loaded"; then
		report "$tag" FAIL "a state loaded by another process ends elsewhere"
	elif cmp -s "$work/$tag.box" "$work/$tag.idle"; then
		report "$tag" FAIL "the run with nothing pressed is the same machine: the pad did not reach the game"
	elif ! awk -v r="${rms:-0}" 'BEGIN { exit !(r > 1) }'; then
		report "$tag" FAIL "the game was silent (sound RMS ${rms:-none})"
	elif [ "${colours:-0}" -lt 2 ]; then
		report "$tag" FAIL "the last picture has ${colours:-no} colours"
	else
		report "$tag" PASS "$frames frames of the pad exercise: native == sandbox == saved and loaded each frame, != idle; a state crosses processes; sound RMS $rms; the last picture has $colours colours"
	fi
}

systems_core() {
	# ------------------------------------------------------------ the NES as published
	# The NES must be exactly the machine it was when it was the package's only
	# one: the core.wbx of MESEN_PUBLISHED_PACKAGE (the package as published)
	# and this one run Nova's 3000-frame schedule to the same frames, picture,
	# sound, lag and memory.
	local pub="${MESEN_PUBLISHED_PACKAGE:-}"
	if [ -z "$pub" ] || [ ! -f "$pub" ]; then
		report "nes:published" SKIP "needs MESEN_PUBLISHED_PACKAGE (the NES package as published)"
	else
		mkdir -p "$work/published-wbx"
		(cd "$work/published-wbx" && unzip -o -q "$pub" core.wbx)
		"$nat/run-wbx" "$work/published-wbx/core.wbx" "$work/nova" --inputs "$root/tests/inputs/nova.inputs" 2>/dev/null | digests > "$work/nova.published"
		if [ ! -s "$work/nova.published" ]; then
			report "nes:published" FAIL "the published core ran nothing"
		elif cmp -s "$work/nova.published" "$work/nova.box"; then
			report "nes:published" PASS "Nova's 3000 frames: the published core and this one give the same frames, picture, sound, lag and every domain"
		else
			report "nes:published" FAIL "$(diff "$work/nova.published" "$work/nova.box" | short)"
		fi
	fi

	# ------------------------------------------------------------ the Super NES
	local snes="$work/snes-roms"
	mkdir -p "$snes"
	python3 -I "$root/tests/snes-test/make-snes-test.py" "$snes"
	sys_program_legs snes snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes"}' 2 480 WRAM
	sys_program_legs snes-multitap snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes","snesPort2":"multitap"}' 5 480 WRAM

	# The chips that run a program of their own: Mesen refuses the cartridge
	# without the program's file (the core says which), and the DSP-1's (and
	# DSP-1B's) program multiplies 0x4000 by 0x4000 into 0x2000 for the test
	# program. The other chips' programs are only seen to load.
	local chip id src got
	for chip in dsp1 dsp1b dsp2 dsp3 dsp4 st010 st011 st018; do
		id="$chip.rom"
		src="$scontent/firmware/SNES_$chip.rom"
		if [ -z "$scontent" ] || [ ! -f "$src" ]; then
			report "snes:chip-$chip" SKIP "needs SNES_$chip.rom in MESEN_SYSTEMS_CONTENT/firmware"
			continue
		fi
		local wn wf
		wn="$(sysdir "chip-$chip-none" "$snes/snes-$chip.sfc" '{"machine":"snes"}')"
		wf="$(sysdir "chip-$chip" "$snes/snes-$chip.sfc" '{"machine":"snes"}' "$src=$id")"
		rw "$wn" --frames 60 > /dev/null 2> "$work/chip.$chip.none.err"
		"$rn" "$wf" --frames 60 --dump-domain WRAM "$work/chip.$chip.ram" 2> "$work/chip.$chip.err" | digests > "$work/chip.$chip.nat"
		rw "$wf" --frames 60 2> "$work/chip.$chip.box.err" | digests > "$work/chip.$chip.box"
		got="$(od -An -tx1 -j48 -N2 "$work/chip.$chip.ram" 2>/dev/null | tr -d ' ')"
		if ! grep -q "error.no_snes_chip" "$work/chip.$chip.none.err"; then
			report "snes:chip-$chip" FAIL "without $id the cartridge was not refused"
		elif [ "$(sed -n 's/^frames=//p' "$work/chip.$chip.box")" != 60 ] || ! cmp -s "$work/chip.$chip.nat" "$work/chip.$chip.box"; then
			report "snes:chip-$chip" FAIL "with $id: $(grep -v '^\[mesen\]' "$work/chip.$chip.box.err" | head -1) $(diff "$work/chip.$chip.nat" "$work/chip.$chip.box" | short)"
		elif { [ "$chip" = dsp1 ] || [ "$chip" = dsp1b ]; } && [ "$got" != 0020 ]; then
			report "snes:chip-$chip" FAIL "the chip's multiply gave $got, not 0020"
		elif { [ "$chip" = dsp1 ] || [ "$chip" = dsp1b ]; }; then
			report "snes:chip-$chip" PASS "refused without $id; with it the chip's program multiplies 0x4000 by 0x4000 into 0x2000; native == sandbox"
		else
			report "snes:chip-$chip" PASS "refused without $id; with it the cartridge runs 60 frames, native == sandbox (the chip's program itself not exercised)"
		fi
	done

	# ------------------------------------------------------------ the Game Boy and Game Boy Color
	sys_program_legs gb gb "$root/tests/roms/gb-test.gb" '{"machine":"gb"}' 1 600 WRAM
	sys_program_legs gbc gbc "$root/tests/roms/gb-test.gb" '{"machine":"gbc"}' 1 600 WRAM
	local gbg="$scontent/systems/gb" gbcg="$scontent/systems/gbc"
	sys_game_leg gb:game:bugsbunny gb "$gbg/Bugs Bunny - Crazy Castle II (U) [!].gb" '{"machine":"gb"}' 1800
	sys_game_leg gb:game:fairy gb "$gbg/A_FAIRY_WITHOUT_WINGS_v1_3_0.gb" '{"machine":"gb"}' 1800
	sys_game_leg gb:game:kirby gb "$gbg/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"gb"}' 1800
	sys_game_leg gb:game:kirby-nintendo-boot gb "$gbg/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"gb","bootRom":"nintendo"}' 1800 GB_dmg.bin=dmg_boot.bin
	sys_game_leg gbc:game:smbdx gbc "$gbcg/Super Mario Bros. Deluxe (USA, Europe) (Rev A).gbc" '{"machine":"gbc"}' 1800
	sys_game_leg gbc:game:gold gbc "$gbcg/Pokemon - Gold Version (UE) [C][!].gbc" '{"machine":"gbc"}' 1800
	sys_game_leg gbc:game:pop gbc "$gbcg/Prince of Persia (USA, Europe).gbc" '{"machine":"gbc"}' 1800
	sys_game_leg gbc:game:slime gbc "$gbcg/aslimetravel.gbc" '{"machine":"gbc"}' 1800
	sys_game_leg gbc:game:smbdx-nintendo-boot gbc "$gbcg/Super Mario Bros. Deluxe (USA, Europe) (Rev A).gbc" '{"machine":"gbc","bootRom":"nintendo"}' 1800 GBC_cgb.bin=cgb_boot.bin

	# ------------------------------------------------------------ the Game Boy Advance
	# Mesen runs no Game Boy Advance game without the console's BIOS, so the
	# free checks are the refusal; the owner's games do the rest.
	local wn
	wn="$(sysdir gba-nobios "$root/tests/roms/gb-test.gb" '{"machine":"gba"}')"
	if rw "$wn" --frames 10 > /dev/null 2> "$work/gba-nobios.err" || ! grep -q "error.no_gba_bios" "$work/gba-nobios.err"; then
		report "gba:bios-required" FAIL "without gba_bios.bin the game was not refused: $(grep -v '^\[mesen\]' "$work/gba-nobios.err" | head -1)"
	else
		report "gba:bios-required" PASS "without the BIOS (gba_bios.bin) a game is refused, and the error names the file"
	fi
	local gbag="$scontent/systems/gba" gbab=GBA_bios.rom=gba_bios.bin
	sys_game_leg gba:game:tollrunner gba "$gbag/tollrunner_jam.gba" '{"machine":"gba"}' 1800 $gbab
	sys_game_leg gba:game:anotherworld gba "$gbag/Another_world.gba" '{"machine":"gba"}' 1800 $gbab
	sys_game_leg gba:game:mmbn gba "$gbag/Megaman Battle Network (U) [!].gba" '{"machine":"gba"}' 1800 $gbab
	sys_game_leg gba:game:rhythmtengoku gba "$gbag/Rhythm Tengoku (J) (V1.0).gba" '{"machine":"gba"}' 1800 $gbab
	sys_game_leg gba:game:warioware gba "$gbag/WarioWare Inc. (U).gba" '{"machine":"gba"}' 1800 $gbab
	sys_game_leg gba:game:yugioh gba "$gbag/Yu-Gi-Oh! - Worldwide Edition - Stairway to the Destined Duel (U) (M6) [!].gba" '{"machine":"gba"}' 1800 $gbab

	# ------------------------------------------------------------ Sega's 8-bit consoles and the ColecoVision
	sys_program_legs sms sms "$root/tests/roms/sms-test.sms" '{"machine":"sms"}' 2 480 "Work RAM"
	sys_program_legs gg gg "$root/tests/roms/gg-test.gg" '{"machine":"gg"}' 1 480 "Work RAM"
	sys_program_legs sg1000 sg1000 "$root/tests/roms/sg-test.sg" '{"machine":"sg1000"}' 2 480 "Work RAM"
	sys_program_legs coleco coleco "$root/tests/roms/cv-test.col" '{"machine":"coleco"}' 2 480 "Work RAM" Coleco_Bios.bin=bios.col
	sys_pause_leg sms:pause sms "$root/tests/roms/sms-test.sms" '{"machine":"sms"}'
	local smsg="$scontent/systems/sms" ggg="$scontent/systems/gamegear" sgg="$scontent/systems/sg1000" cvg="$scontent/systems/coleco"
	sys_game_leg sms:game:mainurse sms "$smsg/mai_nurse_v1.00.sms" '{"machine":"sms"}' 1800
	sys_game_leg sms:game:galactic sms "$smsg/Galactic Protector (Japan).sms" '{"machine":"sms"}' 1800
	sys_game_leg sms:game:pop sms "$ggg/Prince_of_Persia_(UE)_[!].sms" '{"machine":"sms"}' 2400
	sys_game_leg sms:game:mainurse-bios-usa sms "$smsg/mai_nurse_v1.00.sms" '{"machine":"sms","smsBios":"usa"}' 1800 SMS_us_1.3.sms=bios.sms
	sys_game_leg sms:game:galactic-bios-japan sms "$smsg/Galactic Protector (Japan).sms" '{"machine":"sms","smsBios":"japan"}' 1800 SMS_jp_2.1.sms=bios.sms
	sys_game_leg gg:game:frogger gg "$ggg/Frogger (Prototype) [!].gg" '{"machine":"gg"}' 1800
	sys_game_leg gg:game:puyo gg "$ggg/Nazo Puyo Aruru no Ru (J) [!].gg" '{"machine":"gg"}' 1800
	sys_game_leg sg1000:game:pitman sg1000 "$sgg/Pitman.sg" '{"machine":"sg1000"}' 1800
	sys_game_leg sg1000:game:monaco sg1000 "$sgg/Monaco GP (Japan).sg" '{"machine":"sg1000"}' 1800
	sys_game_leg sg1000:game:foryster sg1000 "$sgg/foryster_sg1000.sg" '{"machine":"sg1000"}' 1800
	sys_game_leg coleco:game:carnival coleco "$cvg/Carnival (1982) [a1].col" '{"machine":"coleco"}' 1800 Coleco_Bios.bin=bios.col
	sys_game_leg coleco:game:oilswell coleco "$cvg/Oil's Well (1984)(Sierra On-Line).bin" '{"machine":"coleco"}' 1800 Coleco_Bios.bin=bios.col
	sys_power_leg coleco:power-renamed coleco "$cvg/Oil's Well (1984)(Sierra On-Line).bin" '{"machine":"coleco"}' Coleco_Bios.bin=bios.col

	local g
	g="$scontent/systems/snes"
	sys_game_leg snes:game:smw snes "$g/Super Mario World (U) [!].smc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:lastsuper snes "$g/TheLastSuper.sfc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:topgear2 snes "$g/Top Gear 2 (U) [!].smc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:sailormoon snes "$g/Bishoujo Senshi Sailor Moon S - Jougai Rantou! Shuyaku Soudatsusen (Japan).sfc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:pop snes "$g/Prince of Persia (J).smc" '{"machine":"snes"}' 1800
	sys_game_leg sgb:game:kirby sgb "$scontent/systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"sgb"}' 1800 "SNES_SGB2_(J).sfc=SGB2.sfc"
	sys_game_leg sgb:game:kirby-sgb1 sgb "$scontent/systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"sgb","sgbModel":"sgb1"}' 1800 "SNES_SGB_RevB_(World).sfc=SGB1.sfc"
}

# The Master System's Pause button is the console's: the test program counts
# the interrupts it raises (RAM +5). Pressed on two frames, it counts two,
# native == sandbox. (Mesen does not emulate the SG-1000's Hold button.)
sys_pause_leg() { # tag machine rom settings
	local tag="$1" machine="$2" rom="$3" settings="$4" wd wire n
	wd="$(sysdir "$tag" "$rom" "$settings")"
	wire="$(python3 -I "$sys_py" wire "$machine")"
	python3 -I "$sys_py" hold "$machine" 240 "$work/$tag.inputs" 100:1:Pause 160:1:Pause
	"$rn" "$wd" --frames 240 --inputs "$work/$tag.inputs" --wire "$wire" --dump-domain "Work RAM" "$work/$tag.ram" 2>/dev/null | digests > "$work/$tag.nat"
	rw "$wd" --frames 240 --inputs "$work/$tag.inputs" --wire "$wire" 2>/dev/null | digests > "$work/$tag.box"
	n="$(od -An -tu1 -j5 -N1 "$work/$tag.ram" 2>/dev/null | tr -d ' ')"
	if ! cmp -s "$work/$tag.nat" "$work/$tag.box" || [ ! -s "$work/$tag.box" ]; then
		report "$tag" FAIL "native and sandbox differ"
	elif [ "${n:-0}" != 2 ]; then
		report "$tag" FAIL "Pause pressed on two frames: the program counted ${n:-no} interrupts"
	else
		report "$tag" PASS "Pause pressed on two frames: the program counted 2 interrupts; native == sandbox"
	fi
}

# Power on a game the core gives Mesen from memory under the machine's name
# (a ColecoVision game named .bin): Mesen would reload the game by its path,
# so the core reloads it itself. Power held at frame 600: the run goes on,
# native == sandbox == saved and loaded each frame, and it is not the run
# without the power cycle.
sys_power_leg() { # tag machine file settings [src=id]...
	local tag="$1" machine="$2" file="$3" settings="$4"
	shift 4
	local need
	for need in "$file" "$@"; do
		need="${need%%=*}"
		[ "$need" = "$file" ] || need="$scontent/firmware/$need"
		if [ -z "$scontent" ] || [ ! -f "$need" ]; then
			report "$tag" SKIP "needs $(basename "$need") in MESEN_SYSTEMS_CONTENT"
			return
		fi
	done
	local wd wire
	wd="$(sysdir "$tag" "$file" "$settings" "$@")"
	wire="$(python3 -I "$sys_py" wire "$machine")"
	python3 -I "$sys_py" hold "$machine" 1200 "$work/$tag.inputs" 600:1:Power
	python3 -I "$sys_py" hold "$machine" 1200 "$work/$tag.nopower.inputs"
	local args=(--frames 1200 --inputs "$work/$tag.inputs" --wire "$wire")
	"$rn" "$wd" "${args[@]}" 2>/dev/null | digests > "$work/$tag.nat"
	rw "$wd" "${args[@]}" 2>"$work/$tag.err" | digests > "$work/$tag.box"
	rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$tag.rr"
	rw "$wd" --frames 1200 --inputs "$work/$tag.nopower.inputs" --wire "$wire" 2>/dev/null | digests > "$work/$tag.nopower"
	if [ "$(sed -n 's/^frames=//p' "$work/$tag.box")" != 1200 ]; then
		report "$tag" FAIL "the sandbox did not run 1200 frames: $(grep -v '^\[mesen\]' "$work/$tag.err" | head -1)"
	elif ! cmp -s "$work/$tag.nat" "$work/$tag.box" || ! cmp -s "$work/$tag.box" "$work/$tag.rr"; then
		report "$tag" FAIL "native, sandbox and saved-and-loaded runs differ"
	elif cmp -s "$work/$tag.box" "$work/$tag.nopower"; then
		report "$tag" FAIL "Power changed nothing"
	else
		report "$tag" PASS "Power at frame 600 on a game given under another name: the game starts again; native == sandbox == saved and loaded each frame"
	fi
}

# Through Chimera's engine: the test program's schedule written as a Chimera
# movie with the machine's active controls, made into a project by one
# chimera-run and replayed by another, ends on the native reference's RAM.
sys_engine_leg() { # check machine rom settings players frames domain [src=id]...
	local check="$1" machine="$2" rom="$3" settings="$4" players="$5" frames="$6" domain="$7"
	shift 7
	local pd="$work/eng.$check" fw=() p wd
	for p in "$@"; do
		local src="${p%%=*}"
		[ -f "$src" ] || src="$scontent/firmware/$src"
		if [ ! -f "$src" ]; then
			report "$check" SKIP "needs $(basename "$src") in MESEN_SYSTEMS_CONTENT"
			return
		fi
		fw+=(--firmware "${p##*=}=$src")
	done
	rm -rf "$pd" && mkdir -p "$pd" && cp "$rom" "$pd/"
	python3 -I "$sys_py" schedule "$machine" "$players" "$frames" "$work/$check.inputs"
	python3 -I "$sys_py" movie "$machine" "$players" "$work/$check.inputs" "$work/$check.movie.txt"
	"$runner" --new-project "$pd/p.chimeraProject" "$package" "$pd/$(basename "$rom")" "$work/$check.movie.txt" \
		--settings "$settings" "${fw[@]}" > "$work/$check.make.log" 2>&1
	# the native reference runs with the settings the project recorded (all
	# of them, at the values chimera-run gave the ones --settings left out)
	wd="$(sysdir "eng.$check" "$rom" "$(python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["settings"]))' "$pd/p.chimeraProject" 2>/dev/null)" "$@")"
	"$rn" "$wd" --frames "$frames" --inputs "$work/$check.inputs" --wire "$(python3 -I "$sys_py" wire "$machine")" \
		--dump-domain "$domain" "$work/$check.native.ram" > /dev/null 2>&1
	"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" "${fw[@]}" \
		--dump "$domain=$work/$check.engine.ram" --meta "$work/$check.meta" > "$work/$check.log" 2>&1
	local got seen
	got=$(sed -n 's/^frames=//p' "$work/$check.meta" 2> /dev/null)
	if [ "${got:-0}" != "$frames" ]; then
		report "$check" FAIL "the movie played ${got:-no} frames, not $frames: $(tail -1 "$work/$check.make.log") $(tail -1 "$work/$check.log")"
	elif ! cmp -s "$work/$check.native.ram" "$work/$check.engine.ram"; then
		report "$check" FAIL "the movie through Chimera ends on another $domain than the native run"
	elif [ "$rom" = "${rom#$root/tests/roms/}" ]; then
		report "$check" PASS "a $frames-frame movie ($players players) made into a project and replayed by another chimera-run ends on the native reference's $domain"
	elif ! seen="$(python3 -I "$sys_py" check "$machine" "$players" "$work/$check.inputs" "$work/$check.engine.ram" 2>&1)"; then
		report "$check" FAIL "through Chimera: $seen"
	else
		report "$check" PASS "a $frames-frame movie ($players players) made into a project and replayed by another chimera-run ends on the native reference's $domain; $seen"
	fi
}

# Each read of the controls reaches Chimera as it happens (its input-poll
# callback, chimera#344): the machine's test program reads them every frame.
sys_polls_leg() { # check machine rom settings players frames
	local check="$1" machine="$2" rom="$3" settings="$4" players="$5" frames="$6" pd="$work/polls.$1"
	rm -rf "$pd" && mkdir -p "$pd" && cp "$rom" "$pd/"
	python3 -I "$sys_py" schedule "$machine" 0 "$frames" "$pd/idle.inputs"
	python3 -I "$sys_py" movie "$machine" "$players" "$pd/idle.inputs" "$pd/idle.txt"
	"$runner" --new-project "$pd/p.chimeraProject" "$package" "$pd/$(basename "$rom")" "$pd/idle.txt" --settings "$settings" > "$pd/make.log" 2>&1
	"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" --count-input-polls \
		--meta "$pd/meta" > "$pd/log" 2>&1
	local polls lags
	polls="$(sed -n 's/^inputPolls=//p' "$pd/meta" 2>/dev/null)"
	lags="$(sed -n 's/^lagFrames=//p' "$pd/meta" 2>/dev/null)"
	if [ -n "$polls" ] && [ "$polls" != none ] && [ "$polls" -ge "$frames" ]; then
		report "$check" PASS "$polls reads of the controls in $frames frames reach Chimera's input-poll callback ($lags lag frames)"
	else
		report "$check" FAIL "inputPolls=${polls:-missing} lagFrames=${lags:-?}: $(tail -1 "$pd/log")"
	fi
}

systems_engine() {
	sys_engine_leg engine:snes snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes"}' 2 480 WRAM
	sys_engine_leg engine:snes-multitap snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes","snesPort2":"multitap"}' 5 480 WRAM
	sys_polls_leg engine:snes-polls snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes"}' 2 300
	sys_engine_leg engine:gb gb "$root/tests/roms/gb-test.gb" '{"machine":"gb"}' 1 600 WRAM
	sys_engine_leg engine:gbc gbc "$root/tests/roms/gb-test.gb" '{"machine":"gbc"}' 1 600 WRAM
	sys_polls_leg engine:gb-polls gb "$root/tests/roms/gb-test.gb" '{"machine":"gb"}' 1 300
	sys_engine_leg engine:sms sms "$root/tests/roms/sms-test.sms" '{"machine":"sms"}' 2 480 "Work RAM"
	sys_engine_leg engine:gg gg "$root/tests/roms/gg-test.gg" '{"machine":"gg"}' 1 480 "Work RAM"
	sys_engine_leg engine:sg1000 sg1000 "$root/tests/roms/sg-test.sg" '{"machine":"sg1000"}' 2 480 "Work RAM"
	sys_polls_leg engine:sms-polls sms "$root/tests/roms/sms-test.sms" '{"machine":"sms"}' 2 300
	if [ -n "$scontent" ] && [ -f "$scontent/firmware/Coleco_Bios.bin" ]; then
		sys_engine_leg engine:coleco coleco "$root/tests/roms/cv-test.col" '{"machine":"coleco"}' 2 480 "Work RAM" Coleco_Bios.bin=bios.col
	else
		report "engine:coleco" SKIP "needs Coleco_Bios.bin in MESEN_SYSTEMS_CONTENT/firmware"
	fi
	local mmbn="$scontent/systems/gba/Megaman Battle Network (U) [!].gba"
	if [ -n "$scontent" ] && [ -f "$mmbn" ] && [ -f "$scontent/firmware/GBA_bios.rom" ]; then
		sys_engine_leg engine:gba gba "$mmbn" '{"machine":"gba"}' 1 900 EWRAM GBA_bios.rom=gba_bios.bin
	else
		report "engine:gba" SKIP "needs Megaman Battle Network and GBA_bios.rom in MESEN_SYSTEMS_CONTENT"
	fi
	local kirby="$scontent/systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb"
	if [ -n "$scontent" ] && [ -f "$kirby" ]; then
		sys_engine_leg engine:sgb sgb "$kirby" '{"machine":"sgb"}' 2 900 "GB WRAM" "SNES_SGB2_(J).sfc=SGB2.sfc"
	else
		report "engine:sgb" SKIP "needs Kirby's Hoshinoka-Bi and the Super Game Boy 2 program in MESEN_SYSTEMS_CONTENT"
	fi

	# A movie made with the published NES package plays the same in this one:
	# a project made by chimera-run with MESEN_PUBLISHED_PACKAGE (the package
	# as published, before the other machines) holding Nova's 3000-frame
	# movie, run with this package, ends on the native reference's RAM
	# (run-gate.sh's engine:movie made both).
	local pub="${MESEN_PUBLISHED_PACKAGE:-}"
	if [ -z "$pub" ] || [ ! -f "$pub" ] || [ ! -f "$work/nova.movie.txt" ] || [ ! -f "$work/mv.native.ram" ]; then
		report "engine:nes-published" SKIP "needs MESEN_PUBLISHED_PACKAGE (the NES package as published) and run-gate.sh's engine:movie"
	else
		local pd="$work/published"
		rm -rf "$pd" && mkdir -p "$pd" && cp "$root/tests/roms/nova.nes" "$pd/"
		"$runner" --new-project "$pd/p.chimeraProject" "$pub" "$pd/nova.nes" "$work/nova.movie.txt" > "$pd/make.log" 2>&1
		"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" --allow-core-mismatch \
			--dump "RAM=$pd/ram" --meta "$pd/meta" > "$pd/log" 2>&1
		if [ "$(sed -n 's/^frames=//p' "$pd/meta" 2>/dev/null)" != 3000 ]; then
			report "engine:nes-published" FAIL "the movie did not play 3000 frames: $(tail -1 "$pd/log")"
		elif ! cmp -s "$pd/ram" "$work/mv.native.ram"; then
			report "engine:nes-published" FAIL "the published package's project ends on another RAM in this package"
		else
			report "engine:nes-published" PASS "a project and movie made with the published NES package play in this package to the same RAM (3000 frames of Nova)"
		fi
	fi
}

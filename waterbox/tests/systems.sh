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
#   <tag>:savestate    a save and a load around every frame change nothing
#   <tag>:turbo        no picture for half the run: the same machine, sound
#                      and later pictures, and the first half really undrawn
#   <tag>:session      a state saved half way by one process, loaded by
#                      another, ends on the straight run's machine (and the
#                      same state loaded ten frames off does not)
#   <tag>:bus          the system bus read whole after every frame changes
#                      nothing, and reads the same in both flavors
sys_program_legs() { # tag machine rom settings players frames domain [src=id]...
	local tag="$1" machine="$2" rom="$3" settings="$4" players="$5" frames="$6" domain="$7"
	shift 7
	local wd wire inputs
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
# silence and the last picture has more than a few colours. SKIP when the
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
	elif [ "${colours:-0}" -lt 4 ]; then
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
		report "$check" PASS "a $frames-frame movie of $players pads made into a project and replayed by another chimera-run ends on the native reference's $domain"
	elif ! seen="$(python3 -I "$sys_py" check "$machine" "$players" "$work/$check.inputs" "$work/$check.engine.ram" 2>&1)"; then
		report "$check" FAIL "through Chimera: $seen"
	else
		report "$check" PASS "a $frames-frame movie of $players pads made into a project and replayed by another chimera-run ends on the native reference's $domain; $seen"
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

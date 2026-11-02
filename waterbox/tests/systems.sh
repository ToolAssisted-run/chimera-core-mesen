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

# The other machines' devices beyond the pad (the Super NES Mouse and Super
# Scope, the Master System's Light Phaser, the PC Engine's Avenue Pad 6), on
# the machines' device test programs (machine-devices.py says which):
#   <device>:equivalence  a 240-frame schedule moving every control of the
#                         device, native == sandbox
#   <device>:input        the program's RAM shows the controls (buttons,
#                         movement, where a gun points), and the same
#                         schedule with plain pads in the device's place
#                         reads otherwise
#   <device>:buttons      each button of the device held alone is read as
#                         itself and no other
#   <device>:savestate    a save and a load around every frame change nothing
#   <device>:session      a state saved half way by one process, loaded by
#                         another, ends on the straight run's machine
sys_device_legs() { # device
	local dev="$1" md="$here/tests/machine-devices.py" m rom settings domain wd wire neutral seen
	read -r m rom settings domain <<< "$(python3 -I "$md" info "$dev")"
	domain="${domain//_/ }"
	wd="$(sysdir "dev-$dev" "$root/tests/roms/$rom" "$settings")"
	wire="$(python3 -I "$sys_py" wire "$m")"
	neutral="$(python3 -I "$md" neutral "$dev")"
	python3 -I "$md" schedule "$dev" 240 "$work/$dev.inputs"
	local args=(--frames 240 --inputs "$work/$dev.inputs" --wire "$wire" --neutral "$neutral")
	"$rn" "$wd" "${args[@]}" --dump-domain "$domain" "$work/$dev.nat.ram" 2>/dev/null | digests > "$work/$dev.nat"
	rw "$wd" "${args[@]}" --dump-domain "$domain" "$work/$dev.box.ram" 2>"$work/$dev.box.err" > "$work/$dev.raw"
	digests < "$work/$dev.raw" > "$work/$dev.box"
	if [ "$(sed -n 's/^frames=//p' "$work/$dev.box")" != 240 ]; then
		report "$dev:equivalence" FAIL "the sandbox did not run 240 frames: $(grep -v '^\[mesen\]' "$work/$dev.box.err" | head -1)"
		return
	fi
	if cmp -s "$work/$dev.nat" "$work/$dev.box" && cmp -s "$work/$dev.nat.ram" "$work/$dev.box.ram"; then
		report "$dev:equivalence" PASS "240 frames moving every control of the device, native == sandbox (picture, sound, lag, every domain)"
	else
		report "$dev:equivalence" FAIL "$(diff "$work/$dev.nat" "$work/$dev.box" | short)"
	fi

	# the same schedule with plain pads where the device was
	local plain
	case "$dev" in
	*Tilt)
		# the sensor is the cartridge's: without it is with it level
		plain="$(sysdir "dev-$dev-plain" "$root/tests/roms/$rom" "$settings")"
		"$rn" "$plain" --frames 240 --wire "$wire" --neutral "$neutral" --dump-domain "$domain" "$work/$dev.plain.ram" > /dev/null 2>&1 ;;
	*)
		plain="$(sysdir "dev-$dev-plain" "$root/tests/roms/$rom" "{\"machine\":\"$m\"}")"
		"$rn" "$plain" "${args[@]}" --dump-domain "$domain" "$work/$dev.plain.ram" > /dev/null 2>&1 ;;
	esac
	if ! seen="$(python3 -I "$md" check "$dev" "$work/$dev.inputs" "$work/$dev.box.ram" 2>&1)"; then
		report "$dev:input" FAIL "$seen"
	elif cmp -s "$work/$dev.box.ram" "$work/$dev.plain.ram"; then
		report "$dev:input" FAIL "with plain pads in the device's place the program reads the same"
	else
		report "$dev:input" PASS "$seen; with plain pads in its place (a tilt sensor: level) the program reads otherwise"
	fi

	local n i bad=""
	n="$(python3 -I "$md" buttons "$dev")"
	[ "$n" -gt 0 ] || n=0
	for i in $(seq 0 $((n - 1))); do
		python3 -I "$md" column "$dev" 120 "$i" "$work/$dev.col.inputs"
		"$rn" "$wd" --frames 120 --inputs "$work/$dev.col.inputs" --wire "$wire" --neutral "$neutral" \
			--dump-domain "$domain" "$work/$dev.col.ram" > /dev/null 2>&1
		if ! seen="$(python3 -I "$md" check "$dev" "$work/$dev.col.inputs" "$work/$dev.col.ram" column 2>&1)"; then
			bad="button $i: $seen"
			break
		fi
	done
	if [ -n "$bad" ]; then
		report "$dev:buttons" FAIL "$bad"
	elif [ "$n" -gt 0 ]; then
		report "$dev:buttons" PASS "each of the device's $n buttons, held alone, is read as itself and no other"
	fi

	if rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$dev.rr" && cmp -s "$work/$dev.box" "$work/$dev.rr"; then
		report "$dev:savestate" PASS "a save and a load around each of 240 frames change nothing"
	else
		report "$dev:savestate" FAIL "$(diff "$work/$dev.box" "$work/$dev.rr" | short)"
	fi

	finalDigests < "$work/$dev.raw" > "$work/$dev.straight"
	rw "$wd" "${args[@]}" --save-at 120 "$work/$dev.state" > "$work/$dev.save" 2>/dev/null
	rw "$wd" "${args[@]}" --load-at 120 "$work/$dev.state" 2>/dev/null | finalDigests > "$work/$dev.loaded"
	if ! grep -q "^savedAt=120" "$work/$dev.save" || [ ! -s "$work/$dev.loaded" ]; then
		report "$dev:session" FAIL "no state was saved at frame 120, or the loading process reported nothing"
	elif cmp -s "$work/$dev.straight" "$work/$dev.loaded"; then
		report "$dev:session" PASS "saved at 120 by one process, loaded by another: the same machine at the end"
	else
		report "$dev:session" FAIL "$(diff "$work/$dev.straight" "$work/$dev.loaded" | short)"
	fi
}

# The Master System's revision (smsModel), on sms-model.sms: a read of port
# $3E finds the bus's last byte on the first Master System and $FF on the
# others; the name table's bit 10 is forced to 0 on the first Master System
# and in Mesen's Compatibility (NTSC, register 2's bit 0 clear), so the
# bottom third of the picture is black there and white on the Master System
# 2. Each native == sandbox == saved and loaded each frame.
sys_sms_model_leg() {
	local mo wd res="" same=1 wire
	wire="$(python3 -I "$sys_py" wire sms)"
	for mo in compatibility sms1 sms2; do
		wd="$(sysdir "smsmodel.$mo" "$root/tests/roms/sms-model.sms" "{\"machine\":\"sms\",\"smsModel\":\"$mo\"}")"
		"$rn" "$wd" --frames 30 --wire "$wire" --screenshot "$work/smsmodel.$mo.tga" --dump-domain "Work RAM" "$work/smsmodel.$mo.ram" 2>/dev/null | digests > "$work/smsmodel.$mo.nat"
		rw "$wd" --frames 30 --wire "$wire" 2>/dev/null | digests > "$work/smsmodel.$mo.box"
		rw "$wd" --frames 30 --wire "$wire" --rerecord 2>/dev/null | digests > "$work/smsmodel.$mo.rr"
		{ [ -s "$work/smsmodel.$mo.box" ] && cmp -s "$work/smsmodel.$mo.nat" "$work/smsmodel.$mo.box" && cmp -s "$work/smsmodel.$mo.box" "$work/smsmodel.$mo.rr"; } || same=0
		res="$res $mo:$(python3 -I - "$work/smsmodel.$mo.tga" "$work/smsmodel.$mo.ram" <<'PYSMS'
import sys
d = open(sys.argv[1], "rb").read()
w = d[12] | d[13] << 8
i = (160 * w + 128) * 4
print("%s,%02x" % ("white" if d[18 + i:18 + i + 3] == b"\xff\xff\xff" else "black", open(sys.argv[2], "rb").read()[0x10]))
PYSMS
)"
	done
	if [ "$same" != 1 ]; then
		report "sms:model" FAIL "native, sandbox and saved-and-loaded runs differ"
	elif [ "$res" != " compatibility:black,ff sms1:black,3e sms2:white,ff" ]; then
		report "sms:model" FAIL "the picture's bottom and port \$3E (want black,ff black,3e white,ff):$res"
	else
		report "sms:model" PASS "the picture's bottom third and port \$3E:$res, as each revision gives them; native == sandbox == saved and loaded each frame"
	fi
}

# The PC Engine CD's card (pceCdType): with a disc made here (one data track)
# and the System Card (the owner's), the Arcade Card's machine has the
# Super CD-ROM System's 192 KiB of card RAM and the Arcade Card's own
# memory, the Super CD-ROM System's the card RAM only, the first CD-ROM
# System's neither (the memory domains Mesen registers); native == sandbox.
sys_pce_cd_type_leg() {
	local card="$scontent/firmware/PCECD_3.0-(J).pce" t wd res="" same=1
	if [ -z "$scontent" ] || [ ! -f "$card" ]; then
		report "pcecd:card-type" SKIP "needs PCECD_3.0-(J).pce in MESEN_SYSTEMS_CONTENT/firmware"
		return
	fi
	for t in arcade superCdRom cdRom; do
		wd="$work/cdtype.$t"
		rm -rf "$wd" && mkdir -p "$wd"
		python3 -I - "$wd" <<'PYDISC'
import sys
wd = sys.argv[1]
open(wd + "/disc.cue", "w").write('FILE "disc.img" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
open(wd + "/disc.img", "wb").write(bytes(2352 * 32))
PYDISC
		printf '{"disc":["disc.cue"]}' > "$wd/slots"
		printf '{"machine":"pcecd","pceCdType":"%s"}' "$t" > "$wd/settings"
		cp "$card" "$wd/syscard3.pce"
		"$rn" "$wd" --frames 60 --wire "$(python3 -I "$sys_py" wire pcecd)" 2>/dev/null | digests > "$work/cdtype.$t.nat"
		rw "$wd" --frames 60 --wire "$(python3 -I "$sys_py" wire pcecd)" 2>/dev/null | digests > "$work/cdtype.$t.box"
		{ [ -s "$work/cdtype.$t.box" ] && cmp -s "$work/cdtype.$t.nat" "$work/cdtype.$t.box"; } || same=0
		res="$res $t:$(grep -c '^domain\[Card RAM\]' "$work/cdtype.$t.box"),$(grep -c '^domain\[Arcade Card RAM\]' "$work/cdtype.$t.box")"
	done
	if [ "$same" != 1 ]; then
		report "pcecd:card-type" FAIL "native and sandbox differ"
	elif [ "$res" != " arcade:1,1 superCdRom:1,0 cdRom:0,0" ]; then
		report "pcecd:card-type" FAIL "card RAM, Arcade Card RAM (want 1,1 1,0 0,0):$res"
	else
		report "pcecd:card-type" PASS "the card's memory (card RAM, Arcade Card RAM):$res, as each card has it; native == sandbox"
	fi
}

# An owner's game with the Super NES Mouse: Arkanoid - Doh It Again, a pad in
# port 1 (the pad exercise, which reaches a two-player game) and the mouse in
# port 2, moving right all the time in one run and left in the other. The
# second player's paddle (grey with blue ends, in rows 200-211 of the right
# half of the picture) ends at the right in the first run and at the left in
# the second; each run native == sandbox == saved and loaded each frame.
sys_mouse_game_leg() {
	local game="$scontent/systems/snes/Arkanoid - Doh It Again (J) [!].smc" dx wd centres=""
	if [ -z "$scontent" ] || [ ! -f "$game" ]; then
		report "snes:game:arkanoid-mouse" SKIP "needs Arkanoid - Doh It Again in MESEN_SYSTEMS_CONTENT"
		return
	fi
	for dx in 40 -40; do
		wd="$(sysdir "ark-mouse$dx" "$game" '{"machine":"snes","snesPort2":"mouse"}')"
		local args=(--frames 1800 --exercise --wire 2,12 --pad "$(python3 -I "$sys_py" pad snes)" --neutral "0,0,$dx,0,32768,32768")
		"$rn" "$wd" "${args[@]}" --screenshot "$work/ark$dx.tga" 2>/dev/null | digests > "$work/ark$dx.nat"
		rw "$wd" "${args[@]}" 2>/dev/null | digests > "$work/ark$dx.box"
		rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/ark$dx.rr"
		if [ ! -s "$work/ark$dx.box" ] || ! cmp -s "$work/ark$dx.nat" "$work/ark$dx.box" || ! cmp -s "$work/ark$dx.box" "$work/ark$dx.rr"; then
			report "snes:game:arkanoid-mouse" FAIL "the mouse moving by $dx a frame: native, sandbox and saved-and-loaded runs differ"
			return
		fi
		centres="$centres $(python3 -I - "$work/ark$dx.tga" <<'PYPAD'
import sys
d = open(sys.argv[1], "rb").read()
w = d[12] | d[13] << 8
px = d[18:]
xs = []
for y in range(200, 212):
    for x in range(136, 250):
        b, g, r = px[(y * w + x) * 4:(y * w + x) * 4 + 3]
        if (r, g, b) == (0x18, 0x39, 0x9C) or (r == g == b and 0x40 <= r <= 0x70):
            xs.append(x)
print(sum(xs) // len(xs) if xs else -1)
PYPAD
)"
	done
	local right left
	read -r right left <<< "$centres"
	if [ "$right" -lt 0 ] || [ "$left" -lt 0 ] || [ $((right - left)) -lt 30 ]; then
		report "snes:game:arkanoid-mouse" FAIL "the paddle's middle at x $right with the mouse moving right and $left moving left"
	else
		report "snes:game:arkanoid-mouse" PASS "Arkanoid - Doh It Again, the mouse in port 2: the paddle ends at x $right moving right and x $left moving left; native == sandbox == saved and loaded each frame"
	fi
}

# The WonderSwan Color machine as a SwanCrystal (the setting wscModel): the
# test program keeps port $62, whose bit 7 the SwanCrystal sets, at $0104.
# Set with the SwanCrystal, clear with the WonderSwan Color, on the same
# file; native == sandbox == saved and loaded each frame.
sys_swancrystal_leg() {
	local wc wsc wire bc bs
	wire="$(python3 -I "$sys_py" wire wsc)"
	wc="$(sysdir wsc-color "$root/tests/roms/ws-test.ws" '{"machine":"wsc"}')"
	wsc="$(sysdir wsc-crystal "$root/tests/roms/ws-test.ws" '{"machine":"wsc","wscModel":"swanCrystal"}')"
	"$rn" "$wc" --frames 120 --wire "$wire" --dump-domain "Work RAM" "$work/wsc-color.ram" > /dev/null 2>&1
	"$rn" "$wsc" --frames 120 --wire "$wire" --dump-domain "Work RAM" "$work/wsc-crystal.ram" 2>/dev/null | digests > "$work/wsc-crystal.nat"
	rw "$wsc" --frames 120 --wire "$wire" 2>/dev/null | digests > "$work/wsc-crystal.box"
	rw "$wsc" --frames 120 --wire "$wire" --rerecord 2>/dev/null | digests > "$work/wsc-crystal.rr"
	bc="$(od -An -tu1 -j260 -N1 "$work/wsc-color.ram" 2>/dev/null | tr -d ' ')"
	bs="$(od -An -tu1 -j260 -N1 "$work/wsc-crystal.ram" 2>/dev/null | tr -d ' ')"
	if [ ! -s "$work/wsc-crystal.box" ] || ! cmp -s "$work/wsc-crystal.nat" "$work/wsc-crystal.box" || ! cmp -s "$work/wsc-crystal.box" "$work/wsc-crystal.rr"; then
		report "wsc:swancrystal" FAIL "native, sandbox and saved-and-loaded runs differ"
	elif [ $(( ${bs:-0} & 128 )) = 0 ] || [ $(( ${bc:-128} & 128 )) != 0 ]; then
		report "wsc:swancrystal" FAIL "port \$62 read ${bs:-?} on the SwanCrystal and ${bc:-?} on the WonderSwan Color"
	else
		report "wsc:swancrystal" PASS "the program reads the SwanCrystal's mark (port \$62 bit 7) on the SwanCrystal and not on the WonderSwan Color; native == sandbox == saved and loaded each frame"
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
		[ "$need" = "$file" ] || [ -f "$need" ] || need="$scontent/firmware/$need"
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
	sys_clock_leg snes snes "$snes/snes-rtc.sfc" WRAM '{"machine":"snes"}'

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
	sys_clock_leg gb gb "$root/tests/roms/gb-rtc.gb" WRAM '{"machine":"gb"}'
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
	# A game needs the console's BIOS (refused without it, unless the setting
	# Game Boy Advance BIOS is None); this repository's test program needs
	# none and runs on CI with that setting, which also skips the boot screen.
	sys_program_legs gba gba "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}' 1 600 EWRAM
	sys_gba_rtc_leg
	sys_clock_leg gba gba "$root/tests/roms/gba-test.gba" EWRAM '{"machine":"gba","gbaBios":"none"}'
	sys_gba_skip_leg
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

	# ------------------------------------------------------------ the PC Engine and the WonderSwan
	sys_program_legs pce pce "$root/tests/roms/pce-test.pce" '{"machine":"pce"}' 1 480 "Work RAM"
	sys_program_legs pce-multitap pce "$root/tests/roms/pce-test.pce" '{"machine":"pce","pcePort":"multitap"}' 5 480 "Work RAM"
	sys_program_legs sgx sgx "$root/tests/roms/sgx-test.sgx" '{"machine":"sgx"}' 1 480 "Work RAM"
	sys_program_legs ws ws "$root/tests/roms/ws-test.ws" '{"machine":"ws"}' 1 480 "Work RAM"
	sys_program_legs wsc wsc "$root/tests/roms/ws-test.ws" '{"machine":"wsc"}' 1 480 "Work RAM"
	sys_program_legs pcv2 pcv2 "$root/tests/roms/ws-test.ws" '{"machine":"pcv2"}' 1 480 "Work RAM"
	sys_swancrystal_leg
	sys_clock_leg ws ws "$root/tests/roms/ws-rtc.ws" "Work RAM" '{"machine":"ws"}'

	# ------------------------------------------------------------ the devices beyond the pad
	local dev
	for dev in snesMouse1 snesMouse2 superScope lightPhaser1 lightPhaser2 avenuePad6 avenuePad6Tap \
		nttKeypadSnes1 nttKeypadSnes2 blueRetro gbTilt gbaTilt; do
		sys_device_legs "$dev"
	done
	sys_sms_model_leg
	sys_pce_cd_type_leg
	sys_sgx_leg
	sys_card_leg
	local pceg="$scontent/systems/pcengine" cdg="$scontent/systems/pcEngineCD" wsg="$scontent/systems/wonderswan"
	sys_game_leg pce:game:bomberman pce "$pceg/Bomberman (U).pce" '{"machine":"pce"}' 1800
	sys_game_leg pce:game:bomberman-multitap pce "$pceg/Bomberman (U).pce" '{"machine":"pce","pcePort":"multitap"}' 2400
	sys_game_leg pce:game:bomberman93 pce "$pceg/Bomberman '93 (J).pce" '{"machine":"pce"}' 1800
	sys_game_leg pce:game:bomberman94 pce "$pceg/Bomberman '94 (J).pce" '{"machine":"pce"}' 1800
	sys_game_leg sgx:game:1941 sgx "$pceg/1941 - Counter Attack (J) (SGX).pce" '{"machine":"sgx"}' 1800
	sys_cd_leg pcecd:game:f1team "$cdg/F1 Team Simulation Project F (JP).cue" 3000
	sys_cd_leg pcecd:game:dinosaur "$cdg/Magical Dinosaur Tour (US).cue" 3000
	# what of the disc image stays in memory (patch 0011): after 3000 frames
	# of F1 Team Simulation Project F, which has read the disc all along, a
	# savestate of the whole machine is under 4.5 MiB (3.8 MiB measured with
	# the patch, 5.7 MiB without it: every piece of the image read so far)
	if [ -f "$work/pcecd:game:f1team.raw" ]; then
		local cdwd="$work/sys.pcecd:game:f1team" size
		rw "$cdwd" --frames 3000 --exercise --wire "$(python3 -I "$sys_py" wire pcecd)" --pad "$(python3 -I "$sys_py" pad pcecd)" \
			--save-at 2999 "$work/pcecd.state" > /dev/null 2>&1
		size="$(stat -c %s "$work/pcecd.state" 2>/dev/null)"
		if [ -n "$size" ] && [ "$size" -lt 4718592 ]; then
			report "pcecd:state-size" PASS "a savestate at frame 2999 of F1 Team Simulation Project F is $size bytes"
		else
			report "pcecd:state-size" FAIL "a savestate at frame 2999 is ${size:-not there} bytes"
		fi
	else
		report "pcecd:state-size" SKIP "needs the pcecd:game:f1team run"
	fi
	sys_game_leg wsc:game:saintseiya wsc "$wsg/Saint Seiya - Ougon Densetsu Hen - Perfect Edition (Japan).wsc" '{"machine":"wsc"}' 1800

	local g
	g="$scontent/systems/snes"
	sys_game_leg snes:game:smw snes "$g/Super Mario World (U) [!].smc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:lastsuper snes "$g/TheLastSuper.sfc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:topgear2 snes "$g/Top Gear 2 (U) [!].smc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:sailormoon snes "$g/Bishoujo Senshi Sailor Moon S - Jougai Rantou! Shuyaku Soudatsusen (Japan).sfc" '{"machine":"snes"}' 1800
	sys_game_leg snes:game:pop snes "$g/Prince of Persia (J).smc" '{"machine":"snes"}' 1800
	sys_mouse_game_leg
	sys_game_leg sgb:game:kirby sgb "$scontent/systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"sgb"}' 1800 "SNES_SGB2_(J).sfc=SGB2.sfc"
	sys_game_leg sgb:game:kirby-sgb1 sgb "$scontent/systems/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"sgb","sgbModel":"sgb1"}' 1800 "SNES_SGB_RevB_(World).sfc=SGB1.sfc"
}

# The cartridge's clock on the machine's time (patch 0009): the Game Boy
# Advance test program reads its S-3511A every frame. Mesen's S-3511A starts
# at 2000-01-01 00:00:00 and counts the seconds that pass; after 600 frames
# (10.03 s of the machine's time when the last frame reads it) it says
# 00:00:10, natively and in the sandbox, with the host stopped for 3 s at
# frame 300. Read from the host's clock it would say how long the run took
# on this computer instead.
sys_gba_rtc_leg() {
	local wd cn cb
	wd="$(sysdir gba-rtc "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}')"
	local args=(--frames 600 --wire "$(python3 -I "$sys_py" wire gba)" --stall 300 3000)
	"$rn" "$wd" "${args[@]}" --dump-domain EWRAM "$work/gba-rtc.nat.ram" 2>/dev/null | digests > "$work/gba-rtc.nat"
	rw "$wd" "${args[@]}" --dump-domain EWRAM "$work/gba-rtc.box.ram" 2>"$work/gba-rtc.box.err" | digests > "$work/gba-rtc.box"
	cn="$(od -An -tx1 -j16 -N7 "$work/gba-rtc.nat.ram" 2>/dev/null | tr -d ' \n')"
	cb="$(od -An -tx1 -j16 -N7 "$work/gba-rtc.box.ram" 2>/dev/null | tr -d ' \n')"
	if [ ! -s "$work/gba-rtc.box" ] || ! cmp -s "$work/gba-rtc.nat" "$work/gba-rtc.box"; then
		report "gba:rtc" FAIL "native and sandbox differ (clock native $cn, sandbox $cb)"
	elif [ "$cn" != 00010100000010 ]; then
		report "gba:rtc" FAIL "after 600 frames and a 3 s stop of the host the clock says $cn (year month day weekday hour minute second), not 00010100000010"
	else
		report "gba:rtc" PASS "after 600 frames, the host stopped 3 s on the way, the cartridge's clock says 2000-01-01 00:00:10 in both flavors: the machine's time, not the host's"
	fi
}

# Clock Start reaches the cartridges' clocks (patch 0013, the owner's
# decision of 2026-11-01): a test program that reads its cartridge's clock
# every frame (clocks.py says where it keeps it) runs 600 frames with the
# setting at its default (2000-01-01 00:00:00) and at 2026-11-01 13:45:30,
# natively, in the sandbox and in the sandbox with a save and a load around
# every frame; the clock must say the date and time the project's Clock
# Start gives, moved on by the machine's time. Without the patch every one
# of these clocks starts at 2000-01-01 (the RTC-4513 at nothing at all),
# whatever the setting says.
CLOCK_START=1793540730
sys_clock_leg() { # tag machine rom domain settings
	local tag="$1" m="$2" rom="$3" domain="$4" settings="$5" ck="$here/tests/clocks.py"
	local wire start wd want got gotbox said="" n=0
	wire="$(python3 -I "$sys_py" wire "$m")"
	for start in 946684800 "$CLOCK_START"; do
		n=$((n + 1))
		local set="$settings"
		[ "$start" = 946684800 ] || set="${settings%\}},\"rtcStart\":$start}"
		wd="$(sysdir "$tag-clock$n" "$rom" "$set")"
		local args=(--frames 600 --wire "$wire")
		"$rn" "$wd" "${args[@]}" --dump-domain "$domain" "$work/$tag-clock$n.nat.ram" 2>/dev/null | digests > "$work/$tag-clock$n.nat"
		rw "$wd" "${args[@]}" --dump-domain "$domain" "$work/$tag-clock$n.box.ram" 2>/dev/null | digests > "$work/$tag-clock$n.box"
		rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/$tag-clock$n.rr"
		want="$(python3 -I "$ck" expect "$m" "$start" 600)"
		got="$(python3 -I "$ck" read "$m" "$work/$tag-clock$n.nat.ram" 2>/dev/null)"
		gotbox="$(python3 -I "$ck" read "$m" "$work/$tag-clock$n.box.ram" 2>/dev/null)"
		if [ ! -s "$work/$tag-clock$n.box" ] || ! cmp -s "$work/$tag-clock$n.nat" "$work/$tag-clock$n.box" \
			|| ! cmp -s "$work/$tag-clock$n.box" "$work/$tag-clock$n.rr" || [ "$got" != "$gotbox" ]; then
			report "$tag:clock-start" FAIL "Clock Start $start: native, sandbox and saved-and-loaded runs differ (clock native $got, sandbox $gotbox)"
			return
		fi
		if [ "$got" != "$want" ]; then
			report "$tag:clock-start" FAIL "Clock Start $start: after 600 frames the clock says $(python3 -I "$ck" say "$m" "$got"), not $(python3 -I "$ck" say "$m" "$want")"
			return
		fi
		said="$said${said:+; }$(python3 -I "$ck" say "$m" "$got")"
	done
	report "$tag:clock-start" PASS "after 600 frames the cartridge's clock says $said: Clock Start at its default and at 2026-11-01 13:45:30, moved on by the machine's time; native == sandbox == saved and loaded each frame"
}

# Skip Boot Screen with Nintendo's BIOS (the owner's file): on, the test
# program starts at once in system mode; off, the BIOS runs first and
# refuses a cartridge with no Nintendo logo, so the program never runs.
sys_gba_skip_leg() {
	local bios="$scontent/firmware/GBA_bios.rom"
	if [ -z "$scontent" ] || [ ! -f "$bios" ]; then
		report "gba:skip-boot" SKIP "needs GBA_bios.rom in MESEN_SYSTEMS_CONTENT/firmware"
		return
	fi
	local won woff wire non noff
	wire="$(python3 -I "$sys_py" wire gba)"
	won="$(sysdir gba-skip-on "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaSkipBoot":"on"}' "$bios=gba_bios.bin")"
	woff="$(sysdir gba-skip-off "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaSkipBoot":"off"}' "$bios=gba_bios.bin")"
	"$rn" "$won" --frames 600 --wire "$wire" --dump-domain EWRAM "$work/gba-skip-on.ram" 2>/dev/null | digests > "$work/gba-skip-on.nat"
	rw "$won" --frames 600 --wire "$wire" 2>/dev/null | digests > "$work/gba-skip-on.box"
	"$rn" "$woff" --frames 600 --wire "$wire" --dump-domain EWRAM "$work/gba-skip-off.ram" > /dev/null 2>&1
	non="$(od -An -tu4 -j4 -N4 "$work/gba-skip-on.ram" 2>/dev/null | tr -d ' ')"
	noff="$(od -An -tu4 -j4 -N4 "$work/gba-skip-off.ram" 2>/dev/null | tr -d ' ')"
	if [ ! -s "$work/gba-skip-on.box" ] || ! cmp -s "$work/gba-skip-on.nat" "$work/gba-skip-on.box"; then
		report "gba:skip-boot" FAIL "with the BIOS and the boot screen skipped, native and sandbox differ"
	elif [ "${non:-0}" -lt 590 ] || [ "$(od -An -tu1 -j8 -N1 "$work/gba-skip-on.ram" | tr -d ' ')" != 31 ]; then
		report "gba:skip-boot" FAIL "skipped: the program counted ${non:-no} frames of 600, or did not start in system mode"
	elif [ "${noff:-0}" != 0 ]; then
		report "gba:skip-boot" FAIL "not skipped, the BIOS still let the logo-less program run (${noff} frames)"
	else
		report "gba:skip-boot" PASS "with Nintendo's BIOS: skipped, the program runs from the first frame ($non of 600) in system mode, native == sandbox; not skipped, the BIOS runs first and never starts it"
	fi
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

# The SuperGrafx machine is a SuperGrafx: Mesen builds the second video chip
# (the domain "VRAM 2") for the SuperGrafx machine and not for the PC
# Engine's, the same HuCard in both.
sys_sgx_leg() {
	local wp ws
	wp="$(sysdir sgx-vdc2-pce "$root/tests/roms/pce-test.pce" '{"machine":"pce"}')"
	ws="$(sysdir sgx-vdc2-sgx "$root/tests/roms/pce-test.pce" '{"machine":"sgx"}')"
	rw "$wp" --frames 10 2>/dev/null > "$work/sgx-vdc2.pce"
	rw "$ws" --frames 10 2>/dev/null > "$work/sgx-vdc2.sgx"
	if grep -q '^domain\[VRAM 2\]' "$work/sgx-vdc2.pce"; then
		report "sgx:second-vdc" FAIL "the PC Engine machine has a second video chip"
	elif ! grep -q '^domain\[VRAM 2\]' "$work/sgx-vdc2.sgx"; then
		report "sgx:second-vdc" FAIL "the SuperGrafx machine has no second video chip"
	else
		report "sgx:second-vdc" PASS "the SuperGrafx machine has the second video chip (VRAM 2) and the PC Engine machine not, on the same HuCard"
	fi
}

# A PC Engine CD disc needs its card: a disc made here (a .cue and an image
# of one data track, no game on it) is refused without the card, and the
# card the error names is the Super CD-ROM System card 3.0, or, for the same
# disc with the Games Express signature in sector 0x10, the Games Express
# card (Mesen's own test, PceConsole::LoadFirmware).
sys_card_leg() {
	local wd n ge
	for ge in 0 1; do
		wd="$work/card.$ge"
		rm -rf "$wd" && mkdir -p "$wd"
		python3 -I - "$wd" "$ge" <<'PYDISC'
import sys
wd, ge = sys.argv[1], sys.argv[2] == "1"
open(wd + "/disc.cue", "w").write('FILE "disc.img" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
img = bytearray(2352 * 32)
if ge:
    img[0x10 * 2352 + 16:0x10 * 2352 + 24] = bytes([0x01, 0x43, 0x44, 0x30, 0x30, 0x31, 0x01, 0x00])
open(wd + "/disc.img", "wb").write(bytes(img))
PYDISC
		printf '{"disc":["disc.cue"]}' > "$wd/slots"
		printf '{"machine":"pcecd"}' > "$wd/settings"
		rw "$wd" --frames 10 > /dev/null 2> "$work/card.$ge.err"
	done
	if ! grep -q 'no_pce_card.syscard3.pce' "$work/card.0.err"; then
		report "pcecd:card-required" FAIL "a disc without its card: $(grep -v '^\[mesen\]' "$work/card.0.err" | head -1)"
	elif ! grep -q 'no_pce_card.gecard.pce' "$work/card.1.err"; then
		report "pcecd:card-required" FAIL "a Games Express disc without its card: $(grep -v '^\[mesen\]' "$work/card.1.err" | head -1)"
	else
		report "pcecd:card-required" PASS "a disc is refused without its card, which is the Super CD-ROM System card 3.0, or the Games Express card for a Games Express disc"
	fi
}

# A PC Engine CD game: its .cue and the image it names in the work dir (the
# .sub and .ccd beside them are not the game's: Mesen reads the .cue and the
# image), and the Super CD-ROM System card 3.0. The game leg's checks, and
# the disc's card asked for by SuggestSettings.
sys_cd_leg() { # tag cue frames
	local tag="$1" cue="$2" frames="$3"
	local img="${cue%.cue}.img"
	if [ -z "$scontent" ] || [ ! -f "$cue" ] || [ ! -f "$img" ] || [ ! -f "$scontent/firmware/PCECD_3.0-(J).pce" ]; then
		report "$tag" SKIP "needs $(basename "$cue"), its image and PCECD_3.0-(J).pce in MESEN_SYSTEMS_CONTENT"
		return
	fi
	sys_game_leg "$tag" pcecd "$cue" '{"machine":"pcecd"}' "$frames" "PCECD_3.0-(J).pce=syscard3.pce" "$img=$(basename "$img")"
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
	wd="$(sysdir "eng.$check" "$rom" "$(python3 -I -c 'import json, sys, zipfile; print(json.dumps(json.load(zipfile.ZipFile(sys.argv[1]).open("project.json"))["settings"]))' "$pd/p.chimeraProject" 2>/dev/null)" "$@")"
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

# A device through Chimera's engine: the device's schedule written as a
# Chimera movie (only the machine's active controls: the device's buttons
# and axes, and the pads still plugged in), made into a project by one
# chimera-run and replayed by another, ends on the native reference's RAM,
# which shows the device's controls; and the device's reads reach Chimera's
# input-poll callback.
sys_device_engine_leg() { # device
	local dev="$1" md="$here/tests/machine-devices.py" m rom settings domain pd wd seen
	read -r m rom settings domain <<< "$(python3 -I "$md" info "$dev")"
	domain="${domain//_/ }"
	pd="$work/eng.$dev"
	rm -rf "$pd" && mkdir -p "$pd" && cp "$root/tests/roms/$rom" "$pd/"
	python3 -I "$md" schedule "$dev" 240 "$pd/in.inputs"
	python3 -I "$md" movie "$dev" "$pd/in.inputs" "$pd/movie.txt"
	"$runner" --new-project "$pd/p.chimeraProject" "$package" "$pd/$rom" "$pd/movie.txt" \
		--settings "$settings" > "$pd/make.log" 2>&1
	wd="$(sysdir "eng.$dev" "$root/tests/roms/$rom" "$(python3 -I -c 'import json, sys, zipfile; print(json.dumps(json.load(zipfile.ZipFile(sys.argv[1]).open("project.json"))["settings"]))' "$pd/p.chimeraProject" 2>/dev/null)")"
	"$rn" "$wd" --frames 240 --inputs "$pd/in.inputs" --wire "$(python3 -I "$sys_py" wire "$m")" --neutral "$(python3 -I "$md" neutral "$dev")" \
		--dump-domain "$domain" "$pd/native.ram" > /dev/null 2>&1
	"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" --count-input-polls \
		--dump "$domain=$pd/engine.ram" --meta "$pd/meta" > "$pd/log" 2>&1
	local got polls
	got="$(sed -n 's/^frames=//p' "$pd/meta" 2>/dev/null)"
	polls="$(sed -n 's/^inputPolls=//p' "$pd/meta" 2>/dev/null)"
	if [ "${got:-0}" != 240 ]; then
		report "engine:$dev" FAIL "the movie played ${got:-no} frames, not 240: $(tail -1 "$pd/make.log") $(tail -1 "$pd/log")"
	elif ! cmp -s "$pd/native.ram" "$pd/engine.ram"; then
		report "engine:$dev" FAIL "the movie through Chimera ends on another $domain than the native run"
	elif ! seen="$(python3 -I "$md" check "$dev" "$pd/in.inputs" "$pd/engine.ram" 2>&1)"; then
		report "engine:$dev" FAIL "through Chimera: $seen"
	elif [ -z "$polls" ] || [ "$polls" = none ] || [ "$polls" -lt 240 ]; then
		report "engine:$dev" FAIL "inputPolls=${polls:-missing}: the device's reads did not reach Chimera's input-poll callback"
	else
		report "engine:$dev" PASS "a 240-frame movie of the device made into a project and replayed by another chimera-run ends on the native reference's $domain ($seen); $polls reads of the controls reached Chimera"
	fi
}

# A PC Engine CD game through chimera-run: the .cue given in the disc slot
# and its image as another file of the project; the card SuggestSettings
# names; a movie made into a project by one chimera-run and replayed by
# another ends on the native reference's work RAM.
sys_cd_engine_leg() {
	local cue="$scontent/systems/pcEngineCD/F1 Team Simulation Project F (JP).cue" card="$scontent/firmware/PCECD_3.0-(J).pce"
	local img="${cue%.cue}.img" pd="$work/eng.pcecd" wd
	if [ -z "$scontent" ] || [ ! -f "$cue" ] || [ ! -f "$img" ] || [ ! -f "$card" ]; then
		report "engine:pcecd" SKIP "needs F1 Team Simulation Project F and PCECD_3.0-(J).pce in MESEN_SYSTEMS_CONTENT"
		return
	fi
	rm -rf "$pd" && mkdir -p "$pd" && cp "$cue" "$img" "$pd/"
	python3 -I "$sys_py" schedule pcecd 1 1200 "$work/pcecd.inputs" 300
	python3 -I "$sys_py" movie pcecd 1 "$work/pcecd.inputs" "$work/pcecd.movie.txt"
	"$runner" --new-project "$pd/p.chimeraProject" "$package" --file "disc=$pd/$(basename "$cue")" \
		--movie "$work/pcecd.movie.txt" --settings '{"machine":"pcecd"}' --firmware "syscard3.pce=$card" > "$pd/make.log" 2>&1
	"$runner" --project "$pd/p.chimeraProject" "$package" --suggest > "$pd/suggest.txt" 2>&1
	"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" --firmware "syscard3.pce=$card" \
		--dump "Work RAM=$work/pcecd.engine.ram" --meta "$work/pcecd.meta" > "$pd/log" 2>&1
	wd="$(sysdir eng.pcecd "$cue" "$(python3 -I -c 'import json, sys, zipfile; print(json.dumps(json.load(zipfile.ZipFile(sys.argv[1]).open("project.json"))["settings"]))' "$pd/p.chimeraProject" 2>/dev/null)" "$card=syscard3.pce" "$img=$(basename "$img")")"
	python3 -I -c 'import json, sys; print(json.dumps({"disc": [sys.argv[1]]}))' "$(basename "$cue")" > "$wd/slots"
	"$rn" "$wd" --frames 1200 --inputs "$work/pcecd.inputs" --wire "$(python3 -I "$sys_py" wire pcecd)" \
		--dump-domain "Work RAM" "$work/pcecd.native.ram" > /dev/null 2>&1
	if [ "$(sed -n 's/^frames=//p' "$work/pcecd.meta" 2>/dev/null)" != 1200 ]; then
		report "engine:pcecd" FAIL "the movie did not play 1200 frames: $(tail -1 "$pd/make.log") $(tail -1 "$pd/log")"
	elif ! grep -q 'syscard3.pce' "$pd/suggest.txt"; then
		report "engine:pcecd" FAIL "SuggestSettings did not name the Super CD-ROM System card: $(head -c 200 "$pd/suggest.txt")"
	elif ! cmp -s "$work/pcecd.native.ram" "$work/pcecd.engine.ram"; then
		report "engine:pcecd" FAIL "the movie through Chimera ends on another work RAM than the native run"
	else
		report "engine:pcecd" PASS "F1 Team Simulation Project F: the .cue in the disc slot, its image beside it, the card SuggestSettings names; a 1200-frame movie replayed by another chimera-run ends on the native reference's work RAM"
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
	sys_engine_leg engine:pce pce "$root/tests/roms/pce-test.pce" '{"machine":"pce"}' 1 480 "Work RAM"
	sys_engine_leg engine:pce-multitap pce "$root/tests/roms/pce-test.pce" '{"machine":"pce","pcePort":"multitap"}' 5 480 "Work RAM"
	sys_engine_leg engine:sgx sgx "$root/tests/roms/sgx-test.sgx" '{"machine":"sgx"}' 1 480 "Work RAM"
	sys_engine_leg engine:ws ws "$root/tests/roms/ws-test.ws" '{"machine":"ws"}' 1 480 "Work RAM"
	sys_engine_leg engine:wsc wsc "$root/tests/roms/ws-test.ws" '{"machine":"wsc"}' 1 480 "Work RAM"
	sys_engine_leg engine:gba-test gba "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}' 1 600 EWRAM
	sys_polls_leg engine:gba-polls gba "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}' 1 300
	# Clock Start through Chimera: projects whose Clock Start is 2026-11-01
	# 13:45:30, made by chimera-run with the setting, replayed by another;
	# the Game Boy Advance's and the Game Boy's test programs read their
	# cartridges' clocks at that date and time, moved on by the machine's
	# time (the native reference, given the project's settings, too)
	local ck="$here/tests/clocks.py" cm crom cdom ctag cgot cwant csaid="" cfail=""
	for cm in gba gb; do
		case "$cm" in
		gba) crom="$root/tests/roms/gba-test.gba"; cdom=EWRAM; ctag='{"machine":"gba","gbaBios":"none","rtcStart":'"$CLOCK_START"'}' ;;
		gb) crom="$root/tests/roms/gb-rtc.gb"; cdom=WRAM; ctag='{"machine":"gb","rtcStart":'"$CLOCK_START"'}' ;;
		esac
		sys_engine_leg "engine:$cm-clock" "$cm" "$crom" "$ctag" 1 600 "$cdom"
		cgot="$(python3 -I "$ck" read "$cm" "$work/engine:$cm-clock.engine.ram" 2>/dev/null)"
		cwant="$(python3 -I "$ck" expect "$cm" "$CLOCK_START" 600)"
		if [ "$cgot" != "$cwant" ]; then
			cfail="$cfail${cfail:+; }$cm's clock says ${cgot:-nothing}, not $cwant"
		else
			csaid="$csaid${csaid:+; }$(python3 -I "$ck" say "$cm" "$cgot")"
		fi
	done
	if [ -n "$cfail" ]; then
		report "engine:clock-start" FAIL "through Chimera: $cfail"
	else
		report "engine:clock-start" PASS "projects made by chimera-run with Clock Start 2026-11-01 13:45:30: after 600 frames the clocks say $csaid (the Game Boy Advance's, the Game Boy's)"
	fi
	sys_polls_leg engine:pce-polls pce "$root/tests/roms/pce-test.pce" '{"machine":"pce"}' 1 300
	sys_engine_leg engine:pcv2 pcv2 "$root/tests/roms/ws-test.ws" '{"machine":"pcv2"}' 1 480 "Work RAM"
	local dev
	for dev in snesMouse1 snesMouse2 superScope lightPhaser1 lightPhaser2 avenuePad6 avenuePad6Tap \
		nttKeypadSnes1 nttKeypadSnes2 blueRetro gbTilt gbaTilt; do
		sys_device_engine_leg "$dev"
	done
	sys_cd_engine_leg
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

# nes-devices.sh - the checks of the NES devices of 2026-11-01, sourced by
# waterbox/run-gate.sh, which defines rn, rw, work, root, here, report,
# digests, finalDigests and short.
#
# Each device is read by one of this repository's device test cartridges
# (tests/input-test/make-nes-devices.py: tests/roms/nes-*.nes), which keep
# every byte they read from the ports in RAM; waterbox/tests/nes-devices.py
# writes each device's schedule, its Chimera movie, and works out from
# Mesen's own devices what the cartridge must read.
#
# nesdev_core runs the checks of the core alone (native reference and
# sandbox); nesdev_engine the ones through Chimera's engine (chimera-run),
# called with the runner and the package.

nd_py="$here/tests/nes-devices.py"

# a work dir holding one of the device cartridges as a project mounts it
nd_dir() { # tag rom settings
	local wd="$work/nd.$1"
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$root/tests/roms/$2" "$wd/"
	printf '{"rom":["%s"]}' "$2" > "$wd/slots"
	printf '%s' "$3" > "$wd/settings"
	echo "$wd"
}

#   dev:<device>          a 240-frame schedule moving every control: native
#                         == sandbox == sandboxed with a save and a load
#                         around every frame; the cartridge read what the
#                         device answers on the last frame; with no device
#                         in its place (the project's defaults) it does not
#   dev:<device>-buttons  each button alone (held for the last 30 of 120
#                         frames) gives exactly the device's answer
#   dev:<device>-session  a state saved at frame 120 by one process, loaded
#                         by another, ends on the straight run's machine
nd_device_leg() { # device
	local d="$1" rom settings wd seen plain
	read -r rom settings <<< "$(python3 -I "$nd_py" info "$d")"
	wd="$(nd_dir "$d" "$rom" "$settings")"
	python3 -I "$nd_py" schedule "$d" 240 "$work/nd.$d.inputs"
	local args=(--frames 240 --inputs "$work/nd.$d.inputs")
	"$rn" "$wd" "${args[@]}" --dump-domain RAM "$work/nd.$d.nat.ram" 2>/dev/null | digests > "$work/nd.$d.nat"
	rw "$wd" "${args[@]}" --dump-domain RAM "$work/nd.$d.box.ram" 2>"$work/nd.$d.box.err" > "$work/nd.$d.raw"
	digests < "$work/nd.$d.raw" > "$work/nd.$d.box"
	rw "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/nd.$d.rr"
	local seen_ok plain_ok
	seen="$(python3 -I "$nd_py" check "$d" "$work/nd.$d.inputs" "$work/nd.$d.nat.ram")"
	seen_ok=$?
	local pd
	if [ "$d" = bandaiMic ]; then
		# the microphone is the cartridge's: without it is without its input
		pd="$(nd_dir "$d.plain" "$rom" "$settings")"
		"$rn" "$pd" --frames 240 --dump-domain RAM "$work/nd.$d.plain.ram" > /dev/null 2>&1
	else
		pd="$(nd_dir "$d.plain" "$rom" '{}')"
		"$rn" "$pd" "${args[@]}" --dump-domain RAM "$work/nd.$d.plain.ram" > /dev/null 2>&1
	fi
	plain="$(python3 -I "$nd_py" check "$d" "$work/nd.$d.inputs" "$work/nd.$d.plain.ram")"
	plain_ok=$?
	if [ "$(sed -n 's/^frames=//p' "$work/nd.$d.box")" != 240 ]; then
		report "dev:$d" FAIL "the sandbox did not run 240 frames: $(grep -v '^\[mesen\]' "$work/nd.$d.box.err" | head -1)"
		return
	elif ! cmp -s "$work/nd.$d.nat" "$work/nd.$d.box"; then
		report "dev:$d" FAIL "native and sandbox differ: $(diff "$work/nd.$d.nat" "$work/nd.$d.box" | short)"
	elif ! cmp -s "$work/nd.$d.box" "$work/nd.$d.rr"; then
		report "dev:$d" FAIL "a save and a load around each frame changed the machine"
	elif [ "$seen_ok" != 0 ]; then
		report "dev:$d" FAIL "$settings: $seen"
	elif [ "$plain_ok" = 0 ]; then
		report "dev:$d" FAIL "with the project's default ports the cartridge read the same: $plain"
	else
		report "dev:$d" PASS "$settings: $seen; native == sandbox == saved and loaded each frame; without the device (for the cartridge's microphone, without its input) it reads otherwise"
	fi

	local n i bad=""
	n="$(python3 -I "$nd_py" buttons "$d")"
	if [ "$n" -gt 0 ]; then
		for i in $(seq 0 $((n - 1))); do
			python3 -I "$nd_py" column "$d" 120 "$i" "$work/nd.$d.col.inputs"
			"$rn" "$wd" --frames 120 --inputs "$work/nd.$d.col.inputs" --dump-domain RAM "$work/nd.$d.col.ram" > /dev/null 2>&1
			if ! seen="$(python3 -I "$nd_py" check "$d" "$work/nd.$d.col.inputs" "$work/nd.$d.col.ram")"; then
				bad="button $i: $seen"
				break
			fi
		done
		if [ -n "$bad" ]; then
			report "dev:$d-buttons" FAIL "$bad"
		else
			report "dev:$d-buttons" PASS "each of its $n buttons alone gives what the device answers for it"
		fi
	fi

	finalDigests < "$work/nd.$d.raw" > "$work/nd.$d.straight"
	rw "$wd" "${args[@]}" --save-at 120 "$work/nd.$d.state" > "$work/nd.$d.save" 2>/dev/null
	rw "$wd" "${args[@]}" --load-at 120 "$work/nd.$d.state" 2>/dev/null | finalDigests > "$work/nd.$d.loaded"
	if ! grep -q "^savedAt=120" "$work/nd.$d.save" || [ ! -s "$work/nd.$d.loaded" ]; then
		report "dev:$d-session" FAIL "no state was saved at frame 120, or the loading process reported nothing"
	elif cmp -s "$work/nd.$d.straight" "$work/nd.$d.loaded"; then
		report "dev:$d-session" PASS "saved at 120 by one process, loaded by another: the same machine at the end"
	else
		report "dev:$d-session" FAIL "$(diff "$work/nd.$d.straight" "$work/nd.$d.loaded" | short)"
	fi
}

# Bandai's Hyper Shot sees light as the Zapper does: the cartridge's right
# half is white; pointed there it sees light, sooner the higher it points,
# pointed left none (nes-serial.nes counts the reads of $4017 until light,
# from when its frame's reads end, some 40 lines into the picture: the two
# places pointed at are below that, at lines 109 and 205).
nd_light_leg() {
	local wd light="" same=1 top bottom left
	wd="$(nd_dir light nes-serial.nes '{"port1":"none","expansion":"bandaiHyperShot"}')"
	for xy in "50000 30000" "50000 56000" "10000 32000"; do
		set -- $xy
		for i in $(seq 60); do echo "|..|........|@a3=$1 a4=$2|"; done > "$work/nd.light.inputs"
		"$rn" "$wd" --frames 60 --inputs "$work/nd.light.inputs" --dump-domain RAM "$work/nd.light.ram" > "$work/nd.light.nat" 2>/dev/null
		rw "$wd" --frames 60 --inputs "$work/nd.light.inputs" 2>/dev/null > "$work/nd.light.box"
		cmp -s <(digests < "$work/nd.light.nat") <(digests < "$work/nd.light.box") || same=0
		light="$light$(python3 -I "$here/tests/input-devices.py" light "$work/nd.light.ram");"
	done
	IFS=';' read -r top bottom left _ <<< "$light"
	if [ "$same" != 1 ]; then
		report "dev:bandaiHyperShot-light" FAIL "native and sandbox differ"
	elif [ "${top%% *}" = 1 ] && [ "${bottom%% *}" = 1 ] && [ "${left%% *}" = 0 ] && [ "${top##* }" -lt "${bottom##* }" ]; then
		report "dev:bandaiHyperShot-light" PASS "light seen high on the right after ${top##* } reads, low after ${bottom##* }, never on the left; native == sandbox"
	else
		report "dev:bandaiHyperShot-light" FAIL "seen/reads: right high $top, right low $bottom, left $left"
	fi
}

# The console types (nesModel), on nes-dmc.nes: the sound chip's sample
# channel fetching a byte $FF at its fastest rate while the cartridge reads
# a held pad forty times a frame. A read just after a fetch finds $FF on the
# bus, of which the NES-001 puts $E0 above the controller's bit, the NES-101
# $E4 on $4016, the Famicoms $F8 (NesControlManager::GetOpenBusMask): the
# bits 2 to 4 any read had all run long (RAM $10) tell the three apart. The
# HVC-001's other difference, a controller read twice on two consecutive
# cycles, did not occur with this program (both Famicoms read alike).
nd_model_leg() {
	local m wd res="" same=1 bits
	for i in $(seq 120); do echo "|..|U..R..BA|"; done > "$work/nd.model.inputs"
	for m in nes001 nes101 hvc001 hvc101; do
		wd="$(nd_dir "model.$m" nes-dmc.nes "{\"nesModel\":\"$m\"}")"
		"$rn" "$wd" --frames 120 --inputs "$work/nd.model.inputs" --dump-domain RAM "$work/nd.model.$m.ram" 2>/dev/null | digests > "$work/nd.model.$m.nat"
		rw "$wd" --frames 120 --inputs "$work/nd.model.inputs" 2>/dev/null | digests > "$work/nd.model.$m.box"
		rw "$wd" --frames 120 --inputs "$work/nd.model.inputs" --rerecord 2>/dev/null | digests > "$work/nd.model.$m.rr"
		{ [ -s "$work/nd.model.$m.box" ] && cmp -s "$work/nd.model.$m.nat" "$work/nd.model.$m.box" && cmp -s "$work/nd.model.$m.box" "$work/nd.model.$m.rr"; } || same=0
		bits="$(od -An -tu1 -j16 -N1 "$work/nd.model.$m.ram" 2>/dev/null | tr -d ' ')"
		res="$res $m:$(printf '%02x' $(( ${bits:-0} & 0x1C )))"
	done
	if [ "$same" != 1 ]; then
		report "nes:model" FAIL "native, sandbox and saved-and-loaded runs differ"
	elif [ "$res" != " nes001:00 nes101:04 hvc001:18 hvc101:18" ]; then
		report "nes:model" FAIL "the bus's bits 2 to 4 above the controller's (want 00, 04, 18, 18):$res"
	else
		report "nes:model" PASS "the bus's bits 2 to 4 that reads after a sample fetch had:$res, as each console passes them; native == sandbox == saved and loaded each frame (the two Famicoms read alike here)"
	fi
}

nesdev_core() {
	local d
	for d in $(python3 -I "$nd_py" list); do
		nd_device_leg "$d"
	done
	nd_light_leg
	nd_model_leg
}

# Through Chimera's engine: each device's schedule written as a Chimera movie
# with only the controls the machine has (the core's IsButtonActive and
# IsAxisActive), made into a project by one chimera-run and replayed by
# another, ends on the native reference's RAM, and its reads reach Chimera's
# input-poll callback with no lag frame.
nesdev_engine() { # runner package
	local runner="$1" package="$2" d rom settings fail="" n=0 polls lag pd f
	for d in $(python3 -I "$nd_py" list); do
		read -r rom settings <<< "$(python3 -I "$nd_py" info "$d")"
		pd="$work/nde.$d"
		rm -rf "$pd" && mkdir -p "$pd" && cp "$root/tests/roms/$rom" "$pd/"
		python3 -I "$nd_py" movie "$d" "$work/nd.$d.inputs" "$pd/movie.txt"
		"$runner" --new-project "$pd/p.chimeraProject" "$package" "$pd/$rom" "$pd/movie.txt" \
			--settings "$settings" > "$pd/make.log" 2>&1
		"$runner" --project "$pd/p.chimeraProject" "$package" --files "$pd" --count-input-polls \
			--dump "RAM=$pd/ram" --meta "$pd/meta" > "$pd/log" 2>&1
		f="$(sed -n 's/^frames=//p' "$pd/meta" 2>/dev/null)"
		polls="$(sed -n 's/^inputPolls=//p' "$pd/meta" 2>/dev/null)"
		lag="$(sed -n 's/^lagFrames=//p' "$pd/meta" 2>/dev/null)"
		n=$((n + 1))
		if [ "${f:-0}" != 240 ]; then
			fail="$fail $d: ${f:-no} frames ($(tail -1 "$pd/make.log") $(tail -1 "$pd/log"));"
		elif ! cmp -s "$pd/ram" "$work/nd.$d.nat.ram"; then
			fail="$fail $d: another RAM than native;"
		elif [ "${polls:-0}" -lt "$(od -An -tu1 -N1 "$pd/ram" | tr -d ' ')" ]; then
			# at least one a frame the cartridge read the device in (its
			# frame count, RAM $00: it starts reading on its fourth frame)
			fail="$fail $d: ${polls:-no} input polls;"
		fi
	done
	if [ -z "$fail" ]; then
		report "engine:nes-devices" PASS "the $n devices' schedules as Chimera movies (only the controls each project has) end on the native reference's RAM; their reads reach the input-poll callback on every frame the cartridge reads them (Karaoke Studio's microphone too, through patch 0014)"
	else
		report "engine:nes-devices" FAIL "$fail"
	fi
}

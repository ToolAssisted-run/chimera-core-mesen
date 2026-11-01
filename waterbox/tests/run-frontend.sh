#!/bin/bash
# The frontend test: the Mesen package inside Chimera's window, run headless
# (no display). Each check makes a project with chimera-run --new-project (a
# game runs only in a project), opens it in the window with a Lua script
# that advances frames and dumps the console's RAM, and compares that dump
# byte for byte with the native reference's.
#
# Checks:
#   cart:frontend      Nova, 300 frames with nothing pressed: RAM == native
#   input:frontend     P1 Right+Start held through the window == a native
#                      run of an input file holding the same, != idle
#   settings:port1     port1=none, set in the project: the held buttons go
#                      dead, and the machine still matches its native twin
#   expansion:frontend the four-player adapter in the Famicom's expansion
#                      port, players 3 and 4 held through the window == a
#                      native run of an input file holding the same, != idle
#   epsm:frontend      the EPSM test cartridge with the drums on and the real
#                      rhythm ROM chosen in the window: RAM == native, and the
#                      core's log says the EPSM and the ROM are there
#   sonic:frontend     Sonic The Hedgehog with the EPSM in the expansion port
#                      and the rhythm ROM: RAM == native, the EPSM there
#   fds:frontend       Ai Senshi Nicol with the Disk System's BIOS: RAM ==
#                      native, the disk's two sides found
#                      (these three need MESEN_CONTENT_DIR, the owner's files,
#                      and say SKIP without them)
#   famistudio:frontend  only with MESEN_FAMISTUDIO_ROMS (a folder of EPSM
#                      songs FamiStudio exported to .nes): each one in the
#                      window == native, with the EPSM; SKIP without it
#   keybinds           the package's default keys are the machine's
#
# Usage: ./run-frontend.sh --chimera-root <a built Chimera checkout>
#                          [--package <mesen.chimeraCore>] [--frames N]
#                          [--qt-lib <Qt's lib folder>]
# The package defaults to build/Cores/mesen.chimeraCore of this repository.
# --qt-lib is for a window built against a Qt the system does not know of
# (Chimera's tools/ci-chimera.sh puts Qt 6.12 in <qt>/6.12.0/gcc_64/lib).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=300
chimera_root=""
package="$root/build/Cores/mesen.chimeraCore"
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--package) package="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		--qt-lib) export LD_LIBRARY_PATH="$2${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || {
	echo "pass --chimera-root <a built Chimera checkout>" >&2; exit 2; }
chimera_root="$(cd "$chimera_root" && pwd)"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
crun="$chimera_root/build/dll/chimera-run"
rn="$root/build/meson-native/run-native"
[ -x "$chimera_exe" ] || { echo "Chimera's window not built: $chimera_exe" >&2; exit 1; }
[ -x "$crun" ] || { echo "chimera-run not built: $crun" >&2; exit 1; }
[ -f "$package" ] || { echo "no package at $package (run waterbox/build-package.sh -o build/Cores)" >&2; exit 1; }
[ -x "$rn" ] || { echo "native reference not built" >&2; exit 1; }
package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"

work="$here/work"
rm -rf "$work"
mkdir -p "$work/cores"
# the window sees this package and no other core
cp "$package" "$work/cores/"
package="$work/cores/$(basename "$package")"

# Chimera's window, run headless: its settings, cache and recovery files the
# run's own, and nothing carried over from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$work/cores" CHIMERA_QT_CACHE="$work/qt-cache" CHIMERA_QT_RECOVERY="$work/qt-recovery" \
	CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"
unset DISPLAY WAYLAND_DISPLAY

ok=0
failed=0
report() { printf "%-22s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-22s %-6s %s\n" "Check" "Result" "Detail"
printf "%-22s %-6s %s\n" "-----" "------" "------"

# a project of a cartridge: tag rom settings-json [firmware id=path]
make_project() {
	local tag="$1" rom="$2" settings="$3" fw="${4:-}"
	local dir="$work/project.$tag"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$root/tests/roms/$rom" "$dir/"
	local extra=()
	[ -n "$fw" ] && extra=(--firmware "$fw")
	"$crun" --new-project "$dir/$tag.chimeraProject" "$package" "$dir/$rom" \
		--settings "$settings" "${extra[@]}" > "$dir/make.log" 2>&1 && echo "$dir/$tag.chimeraProject"
}

# the window on a project: tag project window-settings-file frames [held buttons]
run_window() {
	local tag="$1" project="$2" cfg="$3" nframes="$4" hold="${5:-}"
	local job="$work/job.$tag.txt"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=%s\n' "$nframes" "$work/$tag.ram.bin" "$work/$tag.meta.txt" "$hold" > "$job"
	( cd "$work" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$cfg" "--core=$package" "--lua=$here/frontend-ram.lua" "--project=$project" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}

# the native reference: tag rom settings-json [input file] [extra files...]
native_ram() {
	local tag="$1" rom="$2" settings="$3" inputs="${4:-}"
	shift 4 2>/dev/null || shift $#
	local wd="$work/native.$tag"
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$root/tests/roms/$rom" "$wd/"
	printf '{"rom":["%s"]}' "$rom" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	for f in "$@"; do cp "$f" "$wd/"; done
	local extra=(--frames "$frames")
	[ -n "$inputs" ] && extra+=(--inputs "$inputs")
	"$rn" "$wd" "${extra[@]}" --dump-domain RAM "$work/native.$tag.ram.bin" > "$work/native.$tag.txt" 2>&1
}

python3 -I "$here/settings-config.py" "$work/window.json" '{}'

# --- the machine the window builds is the one the core test signed off on ---
p="$(make_project base nova.nes '{}')"
if [ -z "$p" ]; then
	report "cart:frontend" FAIL "no project made (see tests/work/project.base/make.log)"
elif ! native_ram base nova.nes '{}' ""; then
	report "cart:frontend" FAIL "native runner error (see tests/work/native.base.txt)"
elif ! run_window base "$p" "$work/window.json" "$frames"; then
	report "cart:frontend" FAIL "the window did not report OK (see tests/work/base.log)"
elif cmp -s "$work/native.base.ram.bin" "$work/base.ram.bin"; then
	report "cart:frontend" PASS "Nova, $frames frames in the window: RAM identical to the native reference"
else
	report "cart:frontend" FAIL "RAM differs from the native reference"
fi

# --- input through the window, and a setting that unplugs it ---
hold="$work/hold.inputs"
python3 -I - "$hold" "$frames" <<'PYIN'
import sys
open(sys.argv[1], "w").write("|..|...RS...|\n" * int(sys.argv[2]))
PYIN
p="$(make_project hold nova.nes '{}')"
if ! native_ram hold nova.nes '{}' "$hold"; then
	report "input:frontend" FAIL "native runner error (see tests/work/native.hold.txt)"
elif ! run_window hold "$p" "$work/window.json" "$frames" "P1 Right,P1 Start"; then
	report "input:frontend" FAIL "the window did not report OK (see tests/work/hold.log)"
elif ! cmp -s "$work/native.hold.ram.bin" "$work/hold.ram.bin"; then
	report "input:frontend" FAIL "RAM with the held buttons differs from the native reference"
elif cmp -s "$work/hold.ram.bin" "$work/base.ram.bin"; then
	report "input:frontend" FAIL "holding buttons changed nothing"
else
	report "input:frontend" PASS "P1 Right+Start held in the window == the native input file holding them"
fi

p="$(make_project noport nova.nes '{"port1":"none"}')"
if ! native_ram noport nova.nes '{"port1":"none"}' "$hold"; then
	report "settings:port1" FAIL "native runner error (see tests/work/native.noport.txt)"
elif ! run_window noport "$p" "$work/window.json" "$frames" "P1 Right,P1 Start"; then
	report "settings:port1" FAIL "the window did not report OK (see tests/work/noport.log)"
elif ! cmp -s "$work/native.noport.ram.bin" "$work/noport.ram.bin"; then
	report "settings:port1" FAIL "RAM differs from its native reference"
elif cmp -s "$work/noport.ram.bin" "$work/hold.ram.bin"; then
	report "settings:port1" FAIL "port1=none built the same machine as a plugged pad"
else
	report "settings:port1" PASS "port1=none in the project unplugged the pad; RAM == native"
fi

# --- the Famicom's expansion port: the four-player adapter, with players 3
# and 4 held through the window, on this repository's input test cartridge
# (which keeps what it reads from both ports in RAM) ---
hold34="$work/hold34.inputs"
python3 -I - "$hold34" "$frames" <<'PYIN'
import sys
open(sys.argv[1], "w").write("|..|........|........|...R....|....S...|\n" * int(sys.argv[2]))
PYIN
p="$(make_project exp input-test.nes '{"expansion":"fourPlayerAdapter"}')"
if [ -z "$p" ]; then
	report "expansion:frontend" FAIL "no project made (see tests/work/project.exp/make.log)"
elif ! native_ram exp input-test.nes '{"expansion":"fourPlayerAdapter"}' "$hold34" || ! native_ram expidle input-test.nes '{"expansion":"fourPlayerAdapter"}' ""; then
	report "expansion:frontend" FAIL "native runner error (see tests/work/native.exp.txt)"
elif ! run_window exp "$p" "$work/window.json" "$frames" "P3 Right,P4 Start"; then
	report "expansion:frontend" FAIL "the window did not report OK (see tests/work/exp.log)"
elif ! cmp -s "$work/native.exp.ram.bin" "$work/exp.ram.bin"; then
	report "expansion:frontend" FAIL "RAM with players 3 and 4 held differs from the native reference"
elif cmp -s "$work/exp.ram.bin" "$work/native.expidle.ram.bin"; then
	report "expansion:frontend" FAIL "holding players 3 and 4 changed nothing"
else
	report "expansion:frontend" PASS "the four-player adapter in the expansion port: P3 Right and P4 Start held in the window == the native input file holding them"
fi

# --- the owner's files (MESEN_CONTENT_DIR, never in this repository): the
# real rhythm ROM, Sonic The Hedgehog with the EPSM in the expansion port,
# and the Disk System's BIOS with Ai Senshi Nicol. Each check says SKIP
# without its files. The rhythm ROM's SHA-1 is pinned in the package, so a
# made-up file would not be taken (run-gate.sh's engine:epsm-firmware). ---
cdir="${MESEN_CONTENT_DIR:-}"
content() { [ -n "$cdir" ] && [ -f "$cdir/$1" ] && printf '%s' "$cdir/$1"; }
rhythm="$(content ym2608_adpcm_rom.bin)"
# a project of one of the owner's games: tag file settings [firmware id=path]
make_game_project() {
	local tag="$1" file="$2" settings="$3" fw="${4:-}" ext="${2##*.}"
	local dir="$work/project.$tag"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$file" "$dir/game.$ext"
	local extra=()
	[ -n "$fw" ] && extra=(--firmware "$fw")
	"$crun" --new-project "$dir/$tag.chimeraProject" "$package" "$dir/game.$ext" \
		--settings "$settings" "${extra[@]}" > "$dir/make.log" 2>&1 && echo "$dir/$tag.chimeraProject"
}
# its native reference: tag file settings inputs [firmware files mounted by id: id=path...]
native_game_ram() {
	local tag="$1" file="$2" settings="$3" inputs="$4" ext="${2##*.}"
	shift 4
	local wd="$work/native.$tag"
	rm -rf "$wd" && mkdir -p "$wd" && cp "$file" "$wd/game.$ext"
	printf '{"rom":["game.%s"]}' "$ext" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	for f in "$@"; do cp "${f#*=}" "$wd/${f%%=*}"; done
	local extra=(--frames "$frames")
	[ -n "$inputs" ] && extra+=(--inputs "$inputs")
	"$rn" "$wd" "${extra[@]}" --dump-domain RAM "$work/native.$tag.ram.bin" > "$work/native.$tag.txt" 2>&1
}
game_window_leg() { # check tag file settings firmware-id hold-inputs hold-names [what the log must say...]
	local check="$1" tag="$2" file="$3" settings="$4" fwid="$5" fwfile="$6" holdin="$7" holdnames="$8"
	shift 8
	python3 -I "$here/settings-config.py" "$work/window.$tag.json" '{}' "{\"$fwid\": \"$fwfile\"}"
	local p
	p="$(make_game_project "$tag" "$file" "$settings" "$fwid=$fwfile")"
	if [ -z "$p" ]; then
		report "$check" FAIL "no project made (see tests/work/project.$tag/make.log)"; return
	elif ! native_game_ram "$tag" "$file" "$settings" "$holdin" "$fwid=$fwfile"; then
		report "$check" FAIL "native runner error (see tests/work/native.$tag.txt)"; return
	elif ! run_window "$tag" "$p" "$work/window.$tag.json" "$frames" "$holdnames"; then
		report "$check" FAIL "the window did not report OK (see tests/work/$tag.log)"; return
	elif ! cmp -s "$work/native.$tag.ram.bin" "$work/$tag.ram.bin"; then
		report "$check" FAIL "RAM differs from the native reference"; return
	fi
	for line in "$@"; do
		if ! grep -q "$line" "$work/$tag.log"; then
			report "$check" FAIL "the window's log does not say '$line'"; return
		fi
	done
	report "$check" PASS "$frames frames in the window, $holdnames held: RAM == native; the log says: $(printf '%s; ' "$@")"
}

if [ -z "$rhythm" ]; then
	report "epsm:frontend" SKIP "needs ym2608_adpcm_rom.bin in MESEN_CONTENT_DIR (the rhythm ROM's SHA-1 is pinned)"
else
	cp "$root/tests/roms/epsm-test.nes" "$work/epsm-test.nes"
	game_window_leg epsm:frontend epsm "$work/epsm-test.nes" '{"epsmDrums":"on"}' ymf288_adpcm_rom.bin "$rhythm" "$hold" "P1 Right,P1 Start" \
		'EPSM present' 'EPSM rhythm ROM loaded'
fi
sonic="$(content 'Sonic The Hedgehog (FAMICOM 60 PIN GAME).nes')"
if [ -z "$sonic" ] || [ -z "$rhythm" ]; then
	report "sonic:frontend" SKIP "needs Sonic The Hedgehog and ym2608_adpcm_rom.bin in MESEN_CONTENT_DIR"
else
	game_window_leg sonic:frontend sonic "$sonic" '{"expansion":"epsm","epsmDrums":"on"}' ymf288_adpcm_rom.bin "$rhythm" "$hold" "P1 Right,P1 Start" \
		'EPSM present' 'EPSM rhythm ROM loaded'
fi
nicol="$(content 'Ai Senshi Nicol (Japan).fds')"
fdsbios="$(content FDS_disksys-nintendo.rom)"
if [ -z "$nicol" ] || [ -z "$fdsbios" ]; then
	report "fds:frontend" SKIP "needs 'Ai Senshi Nicol (Japan).fds' and FDS_disksys-nintendo.rom in MESEN_CONTENT_DIR"
else
	game_window_leg fds:frontend nicol "$nicol" '{}' disksys.rom "$fdsbios" "$hold" "P1 Right,P1 Start" \
		'Disk System: 2 disk sides'
fi

# --- FamiStudio's EPSM songs in the window (only with MESEN_FAMISTUDIO_ROMS,
# a folder of .nes files FamiStudio exported; not in this repository): each
# cartridge, in a project opened in the window, runs the frames with
# nothing pressed and ends on the native reference's RAM, with the EPSM ---
fsdir="${MESEN_FAMISTUDIO_ROMS:-}"
fsn=0
fsfail=""
if [ -n "$fsdir" ] && [ -d "$fsdir" ]; then
	for f in "$fsdir"/*.nes; do
		[ -f "$f" ] || continue
		fsn=$((fsn + 1))
		dir="$work/project.fs$fsn"
		rm -rf "$dir" && mkdir -p "$dir" && cp "$f" "$dir/song.nes"
		"$crun" --new-project "$dir/fs$fsn.chimeraProject" "$package" "$dir/song.nes" > "$dir/make.log" 2>&1
		wd="$work/native.fs$fsn"
		rm -rf "$wd" && mkdir -p "$wd" && cp "$f" "$wd/song.nes" && printf '{"rom":["song.nes"]}' > "$wd/slots"
		"$rn" "$wd" --frames "$frames" --dump-domain RAM "$work/native.fs$fsn.ram.bin" > "$work/native.fs$fsn.txt" 2>&1
		if [ ! -f "$dir/fs$fsn.chimeraProject" ]; then
			fsfail="$fsfail $(basename "$f"): no project made;"
		elif ! run_window "fs$fsn" "$dir/fs$fsn.chimeraProject" "$work/window.json" "$frames"; then
			fsfail="$fsfail $(basename "$f"): the window did not report OK (see tests/work/fs$fsn.log);"
		elif ! grep -q 'EPSM present' "$work/fs$fsn.log"; then
			fsfail="$fsfail $(basename "$f"): the window's log does not say the EPSM is there;"
		elif ! cmp -s "$work/native.fs$fsn.ram.bin" "$work/fs$fsn.ram.bin"; then
			fsfail="$fsfail $(basename "$f"): RAM differs from the native reference;"
		fi
	done
fi
if [ "$fsn" = 0 ]; then
	report "famistudio:frontend" SKIP "needs MESEN_FAMISTUDIO_ROMS (FamiStudio's exported songs, not in this repository)"
elif [ -z "$fsfail" ]; then
	report "famistudio:frontend" PASS "$fsn FamiStudio cartridges in the window: RAM == native after $frames frames, the EPSM there"
else
	report "famistudio:frontend" FAIL "$fsfail"
fi

# --- the other machines (the Super NES and the rest): a project of the
# machine's test program opened in the window, buttons of two players held
# through it, ends on the native reference's RAM (run with the settings the
# project recorded), which is not the idle run's; and the controller's
# default keys are the machine's. The owner's games (MESEN_SYSTEMS_CONTENT,
# never in this repository) the same, with nothing held; SKIP without them. ---
sys_py="$here/systems.py"
scontent="${MESEN_SYSTEMS_CONTENT:-}"
# how many players a machine's test program reads with these settings: five
# through a multitap; one on the handhelds and on the PC Engine without one
# (whose one pad answers each of the multitap's five reads); two otherwise
players_of() { # machine settings
	case "$2" in *multitap*) echo 5; return ;; esac
	case "$1" in
		gb|gbc|gba|gg|ws|wsc|pcv2|pce|sgx|pcecd) echo 1 ;;
		*) echo 2 ;;
	esac
}
system_window_leg() { # check tag file settings system-id domain hold-names [src=id firmware]...
	local check="$1" tag="$2" file="$3" settings="$4" sysid="$5" domain="$6" holdnames="$7"
	shift 7
	local machine dir p wd fwargs=() fwmap="{}" f src
	machine="$(python3 -I -c 'import json, sys; print(json.loads(sys.argv[1])["machine"])' "$settings")"
	for f in "$@"; do
		src="${f%%=*}"
		[ -f "$src" ] || src="$scontent/firmware/$src"
		if [ ! -f "$src" ]; then
			report "$check" SKIP "needs $(basename "$src") in MESEN_SYSTEMS_CONTENT"; return
		fi
		fwargs+=(--firmware "${f##*=}=$src")
		fwmap="$(python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); d[sys.argv[2]] = sys.argv[3]; print(json.dumps(d))' "$fwmap" "${f##*=}" "$src")"
	done
	python3 -I "$here/settings-config.py" "$work/window.$tag.json" '{}' "$fwmap"
	dir="$work/project.$tag"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$file" "$dir/"
	"$crun" --new-project "$dir/$tag.chimeraProject" "$package" "$dir/$(basename "$file")" \
		--settings "$settings" "${fwargs[@]}" > "$dir/make.log" 2>&1
	p="$dir/$tag.chimeraProject"
	[ -f "$p" ] || { report "$check" FAIL "no project made (see tests/work/project.$tag/make.log)"; return; }
	wd="$work/native.$tag"
	rm -rf "$wd" && mkdir -p "$wd" && cp "$file" "$wd/"
	python3 -I -c 'import json, sys; print(json.dumps({"cart": [sys.argv[1]]}))' "$(basename "$file")" > "$wd/slots"
	python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["settings"]))' "$p" > "$wd/settings"
	for f in "$@"; do src="${f%%=*}"; [ -f "$src" ] || src="$scontent/firmware/$src"; cp "$src" "$wd/${f##*=}"; done
	local specs=() name
	IFS=, read -r -a names <<< "$holdnames"
	for name in "${names[@]}"; do [ -n "$name" ] && specs+=("0:$frames:$name"); done
	python3 -I "$sys_py" hold "$machine" "$frames" "$work/$tag.inputs" "${specs[@]}"
	local wire
	wire="$(python3 -I "$sys_py" wire "$machine")"
	"$rn" "$wd" --frames "$frames" --wire "$wire" --inputs "$work/$tag.inputs" --dump-domain "$domain" "$work/native.$tag.ram.bin" > "$work/native.$tag.txt" 2>&1
	"$rn" "$wd" --frames "$frames" --wire "$wire" --dump-domain "$domain" "$work/native.$tag.idle.bin" > /dev/null 2>&1
	local job="$work/job.$tag.txt"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=%s\nsystem=%s\ndomain=%s\n' "$frames" "$work/$tag.ram.bin" "$work/$tag.meta.txt" "$holdnames" "$sysid" "$domain" > "$job"
	( cd "$work" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/window.$tag.json" "--core=$package" "--lua=$here/frontend-ram.lua" "--project=$p" ) > "$work/$tag.log" 2>&1
	if ! { [ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"; }; then
		report "$check" FAIL "the window did not report OK: $(grep -m1 detail= "$work/$tag.meta.txt" 2>/dev/null) (see tests/work/$tag.log)"
	elif ! cmp -s "$work/native.$tag.ram.bin" "$work/$tag.ram.bin"; then
		report "$check" FAIL "$domain differs from the native reference"
	elif [ -n "$holdnames" ] && cmp -s "$work/$tag.ram.bin" "$work/native.$tag.idle.bin"; then
		report "$check" FAIL "holding $holdnames changed nothing"
	elif [ -n "$holdnames" ] && [ "$file" != "${file#$root/tests/roms/}" ] && \
		! python3 -I "$sys_py" check "$machine" "$(players_of "$machine" "$settings")" "$work/$tag.inputs" "$work/$tag.ram.bin" > "$work/$tag.check.txt" 2>&1; then
		report "$check" FAIL "the test program read: $(cat "$work/$tag.check.txt")"
	else
		report "$check" PASS "$sysid, $frames frames in the window${holdnames:+ with $holdnames held}: $domain == native${holdnames:+, != idle}"
	fi
}
system_keys_leg() { # check tag file settings controller-name [src=id firmware]...
	local check="$1" tag="$2" file="$3" settings="$4" controller="$5" dir p f src fwargs=() fwmap="{}"
	shift 5
	for f in "$@"; do
		src="$scontent/firmware/${f%%=*}"
		fwargs+=(--firmware "${f##*=}=$src")
		fwmap="$(python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); d[sys.argv[2]] = sys.argv[3]; print(json.dumps(d))' "$fwmap" "${f##*=}" "$src")"
	done
	python3 -I "$here/settings-config.py" "$work/window.$tag.json" '{}' "$fwmap"
	dir="$work/project.$tag"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$file" "$dir/"
	"$crun" --new-project "$dir/$tag.chimeraProject" "$package" "$dir/$(basename "$file")" --settings "$settings" "${fwargs[@]}" > "$dir/make.log" 2>&1
	p="$dir/$tag.chimeraProject"
	local job="$work/job.$tag.txt"
	printf 'out=%s\nmeta=%s\n' "$work/$tag.controls.json" "$work/$tag.meta.txt" > "$job"
	( cd "$work" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/window.$tag.json" "--core=$package" "--lua=$here/dump-controls.lua" "--project=$p" ) > "$work/$tag.log" 2>&1
	if [ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"; then
		if python3 -I "$here/check-keybinds.py" "$work/$tag.controls.json" "$wb/default_keybinds.json" "$controller" > "$work/$tag.txt" 2>&1; then
			report "$check" PASS "$(cat "$work/$tag.txt")"
		else
			report "$check" FAIL "$(head -1 "$work/$tag.txt")"
		fi
	else
		report "$check" FAIL "the window did not report OK (see tests/work/$tag.log)"
	fi
}
sgames="$scontent/systems"

system_window_leg snes:frontend snes "$root/tests/roms/snes-test.sfc" '{"machine":"snes"}' SNES WRAM "P1 Right,P1 Start,P2 A"
system_window_leg snes-multitap:frontend snesmt "$root/tests/roms/snes-test.sfc" '{"machine":"snes","snesPort2":"multitap"}' SNES WRAM "P3 B,P5 L"
system_keys_leg snes:keybinds sneskeys "$root/tests/roms/snes-test.sfc" '{"machine":"snes"}' "SNES Controller"
if [ -f "$sgames/snes/Super Mario World (U) [!].smc" ]; then
	system_window_leg snes:game-frontend smw "$sgames/snes/Super Mario World (U) [!].smc" '{"machine":"snes"}' SNES WRAM ""
else
	report "snes:game-frontend" SKIP "needs Super Mario World in MESEN_SYSTEMS_CONTENT"
fi
if [ -f "$sgames/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" ]; then
	system_window_leg sgb:frontend sgb "$sgames/gb/Kirby's Hoshinoka-Bi (J) (V1.1).gb" '{"machine":"sgb"}' SGB "GB WRAM" "" "SNES_SGB2_(J).sfc=SGB2.sfc"
else
	report "sgb:frontend" SKIP "needs Kirby's Hoshinoka-Bi in MESEN_SYSTEMS_CONTENT"
fi

system_window_leg gb:frontend gb "$root/tests/roms/gb-test.gb" '{"machine":"gb"}' GB WRAM "P1 Left,P1 B"
system_window_leg gbc:frontend gbc "$root/tests/roms/gb-test.gb" '{"machine":"gbc"}' GBC WRAM "P1 Down,P1 Start"
system_keys_leg gb:keybinds gbkeys "$root/tests/roms/gb-test.gb" '{"machine":"gb"}' "Game Boy Controls"
if [ -f "$sgames/gbc/Pokemon - Gold Version (UE) [C][!].gbc" ]; then
	system_window_leg gbc:game-frontend gold "$sgames/gbc/Pokemon - Gold Version (UE) [C][!].gbc" '{"machine":"gbc"}' GBC WRAM ""
else
	report "gbc:game-frontend" SKIP "needs Pokemon Gold in MESEN_SYSTEMS_CONTENT"
fi

system_window_leg sms:frontend sms "$root/tests/roms/sms-test.sms" '{"machine":"sms"}' SMS "Work RAM" "P1 Right,P2 Button 1"
system_window_leg gg:frontend gg "$root/tests/roms/gg-test.gg" '{"machine":"gg"}' GG "Work RAM" "P1 Up,P1 Start"
system_window_leg sg1000:frontend sg1000 "$root/tests/roms/sg-test.sg" '{"machine":"sg1000"}' SG "Work RAM" "P1 Button 2,P2 Left"
system_keys_leg sms:keybinds smskeys "$root/tests/roms/sms-test.sms" '{"machine":"sms"}' "Master System Controller"
if [ -f "$scontent/firmware/Coleco_Bios.bin" ]; then
	system_keys_leg coleco:keybinds cvkeys "$root/tests/roms/cv-test.col" '{"machine":"coleco"}' "ColecoVision Controller" "Coleco_Bios.bin=bios.col"
	system_window_leg coleco:frontend coleco "$root/tests/roms/cv-test.col" '{"machine":"coleco"}' CV "Work RAM" "P1 Key 5,P2 Right Button" "Coleco_Bios.bin=bios.col"
else
	report "coleco:frontend" SKIP "needs Coleco_Bios.bin in MESEN_SYSTEMS_CONTENT"
	report "coleco:keybinds" SKIP "needs Coleco_Bios.bin in MESEN_SYSTEMS_CONTENT"
fi
# the Game Boy Advance's test program needs no BIOS (Game Boy Advance BIOS:
# None), so it runs on CI
system_window_leg gba:frontend gba "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}' GBA EWRAM "P1 L,P1 A,P1 Up"
system_keys_leg gba:keybinds gbakeys "$root/tests/roms/gba-test.gba" '{"machine":"gba","gbaBios":"none"}' "Game Boy Advance Controls"
if [ -f "$sgames/gba/Megaman Battle Network (U) [!].gba" ] && [ -f "$scontent/firmware/GBA_bios.rom" ]; then
	system_window_leg gba:game-frontend mmbn "$sgames/gba/Megaman Battle Network (U) [!].gba" '{"machine":"gba"}' GBA EWRAM "" "GBA_bios.rom=gba_bios.bin"
else
	report "gba:game-frontend" SKIP "needs Megaman Battle Network and GBA_bios.rom in MESEN_SYSTEMS_CONTENT"
fi

system_window_leg pce:frontend pce "$root/tests/roms/pce-test.pce" '{"machine":"pce"}' PCE "Work RAM" "P1 Right,P1 Run"
system_window_leg pce-multitap:frontend pcemt "$root/tests/roms/pce-test.pce" '{"machine":"pce","pcePort":"multitap"}' PCE "Work RAM" "P2 I,P5 Up"
system_window_leg sgx:frontend sgx "$root/tests/roms/sgx-test.sgx" '{"machine":"sgx"}' SGX "Work RAM" "P1 Down,P1 II"
system_window_leg ws:frontend ws "$root/tests/roms/ws-test.ws" '{"machine":"ws"}' WS "Work RAM" "P1 X2,P1 Y3,P1 A"
system_window_leg wsc:frontend wsc "$root/tests/roms/ws-test.ws" '{"machine":"wsc"}' WSC "Work RAM" "P1 X1,P1 Start"
# a PC Engine CD game in the window: the .cue in the disc slot, its image a
# second file of the project, the card as firmware
cdcue="$sgames/pcEngineCD/F1 Team Simulation Project F (JP).cue"
cdcard="$scontent/firmware/PCECD_3.0-(J).pce"
if [ -f "$cdcue" ] && [ -f "${cdcue%.cue}.img" ] && [ -f "$cdcard" ]; then
	dir="$work/project.pcecd"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$cdcue" "${cdcue%.cue}.img" "$dir/"
	"$crun" --new-project "$dir/pcecd.chimeraProject" "$package" --file "disc=$dir/$(basename "$cdcue")" \
		--settings '{"machine":"pcecd"}' --firmware "syscard3.pce=$cdcard" > "$dir/make.log" 2>&1
	python3 -I "$here/settings-config.py" "$work/window.pcecd.json" '{}' "{\"syscard3.pce\": \"$cdcard\"}"
	wd="$work/native.pcecd"
	rm -rf "$wd" && mkdir -p "$wd" && cp "$cdcue" "${cdcue%.cue}.img" "$wd/" && cp "$cdcard" "$wd/syscard3.pce"
	python3 -I -c 'import json, sys; print(json.dumps({"disc": [sys.argv[1]]}))' "$(basename "$cdcue")" > "$wd/slots"
	python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["settings"]))' "$dir/pcecd.chimeraProject" > "$wd/settings"
	"$rn" "$wd" --frames "$frames" --wire 1,8 --dump-domain "Work RAM" "$work/native.pcecd.ram.bin" > "$work/native.pcecd.txt" 2>&1
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=\nsystem=PCECD\ndomain=Work RAM\n' "$frames" "$work/pcecd.ram.bin" "$work/pcecd.meta.txt" > "$work/job.pcecd.txt"
	( cd "$work" && MINIHAWK_JOB="$work/job.pcecd.txt" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/window.pcecd.json" "--core=$package" "--lua=$here/frontend-ram.lua" "--project=$dir/pcecd.chimeraProject" ) > "$work/pcecd.log" 2>&1
	if ! { [ -f "$work/pcecd.meta.txt" ] && grep -q "^status=OK" "$work/pcecd.meta.txt"; }; then
		report "pcecd:frontend" FAIL "the window did not report OK (see tests/work/pcecd.log)"
	elif ! cmp -s "$work/native.pcecd.ram.bin" "$work/pcecd.ram.bin"; then
		report "pcecd:frontend" FAIL "Work RAM differs from the native reference"
	else
		report "pcecd:frontend" PASS "PCECD, F1 Team Simulation Project F, $frames frames in the window: Work RAM == native"
	fi
else
	report "pcecd:frontend" SKIP "needs F1 Team Simulation Project F and PCECD_3.0-(J).pce in MESEN_SYSTEMS_CONTENT"
fi
if [ -f "$sgames/wonderswan/Saint Seiya - Ougon Densetsu Hen - Perfect Edition (Japan).wsc" ]; then
	system_window_leg wsc:game-frontend seiya "$sgames/wonderswan/Saint Seiya - Ougon Densetsu Hen - Perfect Edition (Japan).wsc" '{"machine":"wsc"}' WSC "Work RAM" ""
else
	report "wsc:game-frontend" SKIP "needs Saint Seiya in MESEN_SYSTEMS_CONTENT"
fi
system_keys_leg pce:keybinds pcekeys "$root/tests/roms/pce-test.pce" '{"machine":"pce"}' "PC Engine Controller"
system_keys_leg ws:keybinds wskeys "$root/tests/roms/ws-test.ws" '{"machine":"ws"}' "WonderSwan Controls"
system_window_leg pcv2:frontend pcv2 "$root/tests/roms/ws-test.ws" '{"machine":"pcv2"}' PCV2 "Work RAM" "P1 Circle,P1 View,P1 Left"
system_keys_leg pcv2:keybinds pcv2keys "$root/tests/roms/ws-test.ws" '{"machine":"pcv2"}' "Pocket Challenge V2 Controls"

# --- the devices beyond the pad (machine-devices.py): a project whose port
# holds the device, opened in the window, the device's buttons held and its
# axes set through the window (a Lua script, with TAStudio recording), ends
# on the native reference's RAM, which shows those controls ---
device_window_leg() { # check device held-buttons axes(name:value,...)
	local check="$1" dev="$2" holdnames="$3" axes="$4" md="$here/machine-devices.py" m rom settings domain dir p wd sysid
	read -r m rom settings domain <<< "$(python3 -I "$md" info "$dev")"
	domain="${domain//_/ }"
	case "$m" in snes) sysid=SNES ;; sms) sysid=SMS ;; pce) sysid=PCE ;; *) sysid="$m" ;; esac
	python3 -I "$here/settings-config.py" "$work/window.$dev.json" '{}' '{}'
	dir="$work/project.$dev"
	rm -rf "$dir" && mkdir -p "$dir" && cp "$root/tests/roms/$rom" "$dir/"
	"$crun" --new-project "$dir/$dev.chimeraProject" "$package" "$dir/$rom" --settings "$settings" > "$dir/make.log" 2>&1
	p="$dir/$dev.chimeraProject"
	[ -f "$p" ] || { report "$check" FAIL "no project made (see tests/work/project.$dev/make.log)"; return; }
	wd="$work/native.$dev"
	rm -rf "$wd" && mkdir -p "$wd" && cp "$root/tests/roms/$rom" "$wd/"
	python3 -I -c 'import json, sys; print(json.dumps({"cart": [sys.argv[1]]}))' "$rom" > "$wd/slots"
	python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["settings"]))' "$p" > "$wd/settings"
	python3 -I "$md" hold "$dev" "$frames" "$work/$dev.inputs" "$holdnames" "$axes"
	"$rn" "$wd" --frames "$frames" --wire "$(python3 -I "$sys_py" wire "$m")" --neutral "$(python3 -I "$md" neutral "$dev")" \
		--inputs "$work/$dev.inputs" --dump-domain "$domain" "$work/native.$dev.ram.bin" > "$work/native.$dev.txt" 2>&1
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=%s\naxes=%s\nsystem=%s\ndomain=%s\n' "$frames" "$work/$dev.ram.bin" "$work/$dev.meta.txt" \
		"$holdnames" "$axes" "$sysid" "$domain" > "$work/job.$dev.txt"
	( cd "$work" && MINIHAWK_JOB="$work/job.$dev.txt" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/window.$dev.json" "--core=$package" "--lua=$here/frontend-ram.lua" "--project=$p" ) > "$work/$dev.log" 2>&1
	local seen
	if ! { [ -f "$work/$dev.meta.txt" ] && grep -q "^status=OK" "$work/$dev.meta.txt"; }; then
		report "$check" FAIL "the window did not report OK: $(grep -m1 detail= "$work/$dev.meta.txt" 2>/dev/null) (see tests/work/$dev.log)"
	elif ! cmp -s "$work/native.$dev.ram.bin" "$work/$dev.ram.bin"; then
		report "$check" FAIL "$domain differs from the native reference"
	elif ! seen="$(python3 -I "$md" check "$dev" "$work/$dev.inputs" "$work/$dev.ram.bin" 2>&1)"; then
		report "$check" FAIL "the test program read: $seen"
	else
		report "$check" PASS "$sysid, $frames frames in the window with $holdnames held and $axes: $domain == native; $seen"
	fi
}
device_window_leg snesMouse:frontend snesMouse1 "P1 Mouse Left" "P1 Mouse X:-20,P1 Mouse Y:35"
device_window_leg superScope:frontend superScope "P2 Super Scope Cursor" "P2 Super Scope X:20000,P2 Super Scope Y:40000"
device_window_leg lightPhaser:frontend lightPhaser2 "P2 Trigger" "P2 Light Phaser X:30000,P2 Light Phaser Y:20000"
device_window_leg avenuePad6:frontend avenuePad6 "P1 III,P1 VI" ""

# --- the bindings the package ships are the machine's when nobody changed them ---
p="$(make_project keys nova.nes '{}')"
job="$work/job.keys.txt"
printf 'out=%s\nmeta=%s\n' "$work/keys.controls.json" "$work/keys.meta.txt" > "$job"
( cd "$work" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
	"--config=$work/window.json" "--core=$package" "--lua=$here/dump-controls.lua" "--project=$p" ) > "$work/keys.log" 2>&1
if [ -f "$work/keys.meta.txt" ] && grep -q "^status=OK" "$work/keys.meta.txt"; then
	if python3 -I "$here/check-keybinds.py" "$work/keys.controls.json" "$wb/default_keybinds.json" "NES Controller" > "$work/keys.txt" 2>&1; then
		report "keybinds" PASS "$(cat "$work/keys.txt")"
	else
		report "keybinds" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "keybinds" FAIL "the window did not report OK (see tests/work/keys.log)"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]

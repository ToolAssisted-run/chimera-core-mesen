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
#   epsm:frontend      the EPSM test cartridge with the drums on and a
#                      made-up rhythm ROM chosen in the window: RAM == native,
#                      and the core's log says the EPSM and the ROM are there
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

# --- the EPSM, its drums on and a rhythm ROM chosen in the window ---
python3 -I - "$work/rhythm.bin" <<'PYROM'
import random, sys
r = random.Random(410)
open(sys.argv[1], "wb").write(bytes(r.randrange(256) for _ in range(8192)))
PYROM
python3 -I "$here/settings-config.py" "$work/window.fw.json" '{}' "{\"ymf288_adpcm_rom.bin\": \"$work/rhythm.bin\"}"
p="$(make_project epsm epsm-test.nes '{"epsmDrums":"on"}' "ymf288_adpcm_rom.bin=$work/rhythm.bin")"
cp "$work/rhythm.bin" "$work/ymf288_adpcm_rom.bin"
if [ -z "$p" ]; then
	report "epsm:frontend" FAIL "no project made (see tests/work/project.epsm/make.log)"
elif ! native_ram epsm epsm-test.nes '{"epsmDrums":"on"}' "$hold" "$work/ymf288_adpcm_rom.bin"; then
	report "epsm:frontend" FAIL "native runner error (see tests/work/native.epsm.txt)"
elif ! run_window epsm "$p" "$work/window.fw.json" "$frames" "P1 Right,P1 Start"; then
	report "epsm:frontend" FAIL "the window did not report OK (see tests/work/epsm.log)"
elif ! cmp -s "$work/native.epsm.ram.bin" "$work/epsm.ram.bin"; then
	report "epsm:frontend" FAIL "RAM differs from the native reference"
elif ! grep -q 'EPSM present' "$work/epsm.log"; then
	report "epsm:frontend" FAIL "the window's log does not say the EPSM is plugged in"
elif ! grep -q 'EPSM rhythm ROM loaded' "$work/epsm.log"; then
	report "epsm:frontend" FAIL "the rhythm ROM chosen in the window did not reach Mesen"
else
	report "epsm:frontend" PASS "the EPSM cartridge in the window: RAM == native, the EPSM and its rhythm ROM are there"
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

#!/bin/sh
# Makes sure patches/ are applied to the extern/MesenCE submodule tree.
#
# The submodule pin is pristine upstream; every change is a numbered patch in
# patches/, applied to the working tree here (meson runs this at every
# configure). The series is all or nothing: a tree that has the marker of
# the LAST patch is taken to have them all, a clean tree gets them all, and
# anything in between is refused. After editing patches/, put the submodule
# back to its pin (git -C extern/MesenCE checkout -- . ) and configure again.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
sub="$root/extern/MesenCE"

# a clone made without --recursive leaves an empty directory, and git would
# then answer for this repository instead of the submodule
[ -f "$sub/Core/Shared/Emulator.cpp" ] || {
	echo "extern/MesenCE is empty: git submodule update --init" >&2; exit 1; }
top="$(git -C "$sub" rev-parse --show-toplevel)"
[ "$(cd "$top" && pwd -P)" = "$(cd "$sub" && pwd -P)" ] || {
	echo "extern/MesenCE is not a checkout of its own" >&2; exit 1; }

last="$(ls "$root"/patches/*.patch | sort | tail -1)"
marker="$(sed -n 's/^# marker: //p' "$root/patches/series-marker" 2>/dev/null || true)"
if [ -n "$marker" ] && grep -rqF "$marker" "$sub/Core" "$sub/Utilities" 2>/dev/null; then
	exit 0
fi
if ! git -C "$sub" diff --quiet; then
	echo "extern/MesenCE has changes that are not this repository's patches; put it back to its pin first" >&2
	exit 1
fi
for p in "$root"/patches/*.patch; do
	git -C "$sub" apply "$p"
	echo "applied $(basename "$p")"
done

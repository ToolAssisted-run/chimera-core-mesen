#!/bin/sh
# Checks that a core.wbx holds no network code: none of the C library's
# socket functions is linked in, and nothing of Mesen's netplay or of
# luasocket is. Chimera has no network code, and the owner decided
# (2026-10-31) that this core has none either: patches/0006 and
# waterbox/list-sources.py leave it out of the build.
#
# Usage: check-no-network.sh <core.wbx>
# Prints what it found and exits 1 when it found anything.
set -u
wbx="$1"
[ -f "$wbx" ] || { echo "no such file: $wbx" >&2; exit 2; }
syms="$(nm "$wbx" 2> /dev/null)" || { echo "nm could not read $wbx" >&2; exit 2; }
# the socket calls of the C library, and the name lookups that go with them
found="$(printf '%s\n' "$syms" | awk '{print $NF}' | grep -xE \
	'socket|socketpair|connect|bind|listen|accept|accept4|send|sendto|sendmsg|recv|recvfrom|recvmsg|getsockopt|setsockopt|getsockname|getpeername|shutdown|getaddrinfo|gethostbyname|gethostbyname2|gethostbyaddr|getnameinfo|res_query|__res_msend')"
# Mesen's netplay classes and luasocket's entry points (C++ names mangled)
found="$found
$(printf '%s\n' "$syms" | grep -oE 'GameServer|GameClient|SocketC?[0-9]|6Socket|luaopen_socket_core|luaopen_mime_core' | sort -u)"
found="$(printf '%s\n' "$found" | sed '/^$/d')"
if [ -n "$found" ]; then
	echo "network code in $wbx:" $(printf '%s' "$found" | tr '\n' ' ')
	exit 1
fi
echo "no socket call, no netplay, no luasocket in $wbx"
exit 0

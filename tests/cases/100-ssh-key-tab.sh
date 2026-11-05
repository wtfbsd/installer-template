#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The SSH public key box of the users page is a text view: Tab must go to
# the next control, not into the text (a person cannot type a tab in a
# key, and the box was a trap for the keyboard alone).

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-sshtab.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 83) % 400 ) + 5100 ))
	broadwayd ":${n}" >/dev/null 2>&1 &
	bpid=$!
	for wait in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "${bpid}" 2>/dev/null || break
		if BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway bin/installer-gui --check >/dev/null 2>&1; then
			ready=yes
			break
		fi
		sleep 0.5
	done
	[ "${ready}" = no ] || break
	kill "${bpid}" 2>/dev/null || :
done
trap 'kill "${bpid}" 2>/dev/null; rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
check "broadwayd started" yes "${ready}"

sed "s/^OS=.*/OS=freebsd/" installer.conf | grep -v '^MIN_DISK_GB=' > "${tmp}/freebsd.conf"
printf 'MIN_DISK_GB=1\n' >> "${tmp}/freebsd.conf"
printf '%s\n' '[{"name": "users", "page": "users", "full": false, "state": {"report": "users"}}]' \
	> "${tmp}/users.json"
mkdir -p "${tmp}/users"
if ! GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_MNTTAB=/nonexistent \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/one-disk.conf" \
	bin/installer-gui --render "${tmp}/users.json" --size 1024x768 --screenshots "${tmp}/users" \
	> "${tmp}/users.log" 2>&1; then
	cat "${tmp}/users.log" >&2
fi
r() {
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/users/users.users.json" "$1" 2>&1
}
check "the SSH key box takes no tab" False "$(r 'r["accepts_tab"]')"
check "the SSH key box has the focus before the tab" True "$(r 'r["focus_was_the_box"]')"
check "Tab goes from the SSH key box to the next control" True "$(r 'r["focus_left_the_box"]')"
check "no tab goes into the SSH key box" False "$(r 'r["tab_inserted"]')"

finish

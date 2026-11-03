#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Encrypting the system encrypts the swap too, where the system offers it:
# ticking the box ticks "Encrypt the swap" (the person may untick it), the
# plan and the summary say so.  The hint that asks for a passphrase goes
# as soon as both fields hold the same good passphrase.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-encdef.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 79) % 400) + 4300 ))
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

# render <name> <os> <fixture> <spec>
render() {
	sed "s/^OS=.*/OS=$2/" installer.conf | grep -v '^MIN_DISK_GB=' > "${tmp}/$1.conf"
	printf 'MIN_DISK_GB=1\n' >> "${tmp}/$1.conf"
	printf '%s\n' "$4" > "${tmp}/$1.json"
	mkdir -p "${tmp}/$1"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="${tmp}/$1.conf" INSTALLER_MNTTAB=/nonexistent \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/$3" \
		bin/installer-gui --render "${tmp}/$1.json" --size 1024x768 --screenshots "${tmp}/$1" \
		> "${tmp}/$1.log" 2>&1 || cat "${tmp}/$1.log" >&2
}
r() { # r <name> <shot> <report> <expression>
	python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/$1/$2.$3.json" "$4" 2>&1
}

render fb freebsd dual-os.conf '[
 {"name": "on", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "passphrase": "Correct-Horse-9", "report": "encryption"}},
 {"name": "untick", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "passphrase": "Correct-Horse-9", "swap_encrypted": false, "report": "encryption"}},
 {"name": "typed", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "report": "encryption", "type_after": "Correct-Horse-9"}},
 {"name": "summary", "page": "summary", "full": false, "state": {"report": "page"}, "disk_state": {"mode": "erase", "selected": ["nda0"], "usage": "together", "encrypt": true, "passphrase": "Correct-Horse-9"}}]'
check "encrypting the system encrypts the swap by default (plan)" "{'enabled': True, 'swap': True}" \
	"$(r fb on encryption 'r["plan"]')"
check "the person may untick it" "{'enabled': True, 'swap': False}" "$(r fb untick encryption 'r["plan"]')"
check "the passphrase hint is there while the fields are empty" yes \
	"$(r fb typed encryption '"yes" if "type a passphrase" in r["problems_before"] else r["problems_before"]')"
check "the passphrase hint goes once both fields hold it" "" "$(r fb typed encryption 'r["problems"]')"
check "the summary says the swap is encrypted" yes \
	"$(r fb summary page '"yes" if any("(encrypted)" in t for t in r["texts"]) else r["texts"]')"

# illumos does not encrypt the swap: nothing ticked, nothing shown.
render il illumos captured-illumos.conf '[
 {"name": "on", "page": "disk", "full": false, "state": {"mode": "erase", "encrypt": true, "passphrase": "Correct-Horse-9", "report": "encryption"}}]'
check "illumos: home encryption on, no swap encryption, no box" "{'enabled': True, 'swap': False} False" \
	"$(r il on encryption 'str(r["plan"]) + " " + str(r["swap_shown"])')"

finish

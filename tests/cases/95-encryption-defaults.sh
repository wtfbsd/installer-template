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
	if ! GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="${tmp}/$1.conf" INSTALLER_MNTTAB=/nonexistent \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/$3" \
		bin/installer-gui --render "${tmp}/$1.json" --size 1024x768 --screenshots "${tmp}/$1" \
		> "${tmp}/$1.log" 2>&1; then
		cat "${tmp}/$1.log" >&2
		return 1
	fi
}
r() { # r <name> <shot> <report> <expression>
	python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/$1/$2.$3.json" "$4" 2>&1
}
yn() { # yn <name> <shot> <report> <expression> — yes or no
	python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print("yes" if eval(sys.argv[2]) else "no")' \
		"${tmp}/$1/$2.$3.json" "$4" 2>&1
}

if ! render fb freebsd dual-os.conf '[
 {"name": "on", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "passphrase": "Correct-Horse-9", "report": "encryption"}},
 {"name": "untick", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "passphrase": "Correct-Horse-9", "swap_encrypted": false, "report": "encryption"}},
 {"name": "typed", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "report": "encryption", "type_after": "Correct-Horse-9"}},
 {"name": "untick_enc", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "encrypt": true, "untick_after": true, "report": "encryption"}},
 {"name": "summary", "page": "summary", "full": false, "state": {"report": "page"}, "disk_state": {"mode": "erase", "selected": ["nda0"], "usage": "together", "encrypt": true, "passphrase": "Correct-Horse-9"}}]'; then
	check "render freebsd" ok fail
fi
check "the system is encrypted" yes "$(yn fb on encryption 'r["plan"]["enabled"]')"
check "encrypting the system encrypts the swap by default" yes \
	"$(yn fb on encryption 'r["plan"]["swap"]')"
check "the swap box is ticked" yes "$(yn fb on encryption 'r["swap_active"]')"
check "the swap box is shown where the system offers it" yes \
	"$(yn fb on encryption 'r["swap_shown"]')"
check "the plan, the box and the state agree" yes \
	"$(yn fb on encryption 'r["plan"]["swap"] == r["swap_shown"] == r["swap_active"]')"
check "the person may untick it" no "$(yn fb untick encryption 'r["swap_active"]')"
check "the plan follows the unticking" no "$(yn fb untick encryption 'r["plan"]["swap"]')"
check "the passphrase hint is there while the fields are empty" yes \
	"$(r fb typed encryption '"yes" if "type a passphrase" in r["problems_before"] else r["problems_before"]')"
check "the passphrase hint goes once both fields hold it" "" "$(r fb typed encryption 'r["problems"]')"
# The banner of the window asks for a passphrase that is not wanted any
# more when the encryption is unticked: it goes with it.
check "the window asked for the passphrase" yes \
	"$(r fb untick_enc encryption '"yes" if "type a passphrase" in r["error_before"] else r["error_before"]')"
check "the banner goes when the encryption is unticked" "" \
	"$(r fb untick_enc encryption 'r["error"]')"
check "the summary says the swap is encrypted" yes \
	"$(r fb summary page '"yes" if any("wap" in t and "(encrypted)" in t for t in r["texts"]) else r["texts"]')"

# illumos does not encrypt the swap: nothing ticked, nothing shown.
if ! render il illumos captured-illumos.conf '[
 {"name": "on", "page": "disk", "full": false, "state": {"mode": "erase", "encrypt": true, "passphrase": "Correct-Horse-9", "report": "encryption"}}]'; then
	check "render illumos" ok fail
fi
check "illumos: the home directories are encrypted" yes \
	"$(yn il on encryption 'r["plan"]["enabled"]')"
check "illumos: the swap is not encrypted" no "$(yn il on encryption 'r["plan"]["swap"]')"
check "illumos: no swap box" no "$(yn il on encryption 'r["swap_shown"]')"
check "illumos: the swap box is not ticked" no "$(yn il on encryption 'r["swap_active"]')"

finish

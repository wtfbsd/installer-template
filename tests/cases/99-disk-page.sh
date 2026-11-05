#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The Disk page of the graphical front end:
#
#   - the heading of the "Before and after" box names every disk once (a
#     model that is the name of the disk itself is not said twice);
#   - the label of the encryption box has no nested parentheses (the method
#     of the system goes in parentheses of its own);
#   - the page ticks the first disk with nothing on it, and no disk at all
#     when every disk holds something: the person chooses.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-diskpage.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 71) % 400 ) + 4700 ))
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

# render <name> <os> <fixture> <spec> — draw the shots of the spec.
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
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/$1/$2.$3.json" "$4" 2>&1
}

# ---------------------------------------------------------------- heading

# A disk whose model is the name of the disk itself (a DragonFly virtio
# disk whose kernel messages name no description).
render model freebsd model-name.conf '[
 {"name": "one", "page": "disk", "full": false, "state": {"mode": "erase", "report": "page"}}]'
check "the heading of the Before and after box names the disk once" \
	"['Before and after — vbd2']" \
	"$(r model one 'page' '[t for t in r["texts"] if t.startswith("Before and after")]')"
check "the heading of the Before and after box says the name of the disk once" "[]" \
	"$(r model one 'page' '[t for t in r["texts"] if t.count("vbd2") > 1]')"

# ---------------------------------------------------------------- encryption

# The label of the encryption box of every system: the method of the
# system goes in parentheses of its own, never two pairs.
for os in freebsd netbsd openbsd dragonfly illumos; do
	case "${os}" in
		dragonfly) fixture=render-dragonfly.conf ;;
		*) fixture=one-disk.conf ;;
	esac
	render "enc-${os}" "${os}" "${fixture}" '[
 {"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "usage"}}]'
	label=$(r "enc-${os}" disk usage 'r["enc_label"]')
	check "${os}: the label of the encryption box has no nested parentheses" "" \
		"$(printf '%s' "${label}" | grep -o '([^)]*(' || true)"
	check "${os}: the label of the encryption box names the method of the system" yes \
		"$(case "${label}" in *'('*')'*) echo yes ;; *) echo no ;; esac)"
done
check "dragonfly: the box says the method of the system without a pair of its own" \
	"Encrypt the system (dm_crypt/LUKS); the passphrase is asked at every start" \
	"$(r enc-dragonfly disk usage 'r["enc_label"]')"

# ---------------------------------------------------------------- the disk that is ticked

# The first disk holds Windows and Linux, the second one is empty: the
# empty one is ticked, not the first.
render dual freebsd dual-os.conf '[
 {"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "usage"}}]'
check "the page ticks the disk with nothing on it, not the first disk" "['da0']" \
	"$(r dual disk usage 'r["selected"]')"

# Every disk holds something: the page ticks none of them (the person
# chooses).
render two freebsd two-os.conf '[
 {"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "usage"}}]'
check "the page ticks no disk when every disk holds something" "[]" \
	"$(r two disk usage 'r["selected"]')"

finish

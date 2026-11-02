#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Every picture and every rehearsal offers the full lists of the system:
# every zone of the zone table (the installer's own table, from the IANA
# tzdb, when the system's cannot be read: a warning in the log), and the
# keymaps of the system (its full list when its directory cannot be read).
# The time zone page filters the ~300 zones as one types and scrolls.
# Every password and passphrase field has an eye that shows and hides it;
# showing one shows only that field, and leaving the page hides it again.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-lists.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
backend="${root}/bin/installer-backend"

zones=$(( $(grep -vc '^#' lib/zone1970.tab) + 1 ))
count() { # count <os> <section> <key> — the length of a list of a probe
	sed "s/^OS=.*/OS=$1/" installer.conf > "${tmp}/$1.conf"
	INSTALLER_CONF="${tmp}/$1.conf" INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
		"${backend}" "$2" probe 2>/dev/null | python3 -I -c '
import json, sys; print(len(json.load(sys.stdin)[sys.argv[1]]))' "$3"
}
for os in freebsd netbsd openbsd dragonfly illumos; do
	check "${os}: a rehearsal offers every zone of the table (${zones})" "${zones}" "$(count "${os}" timezone zones)"
done
check "freebsd: the keymaps of FreeBSD (more than 80)" yes "$([ "$(count freebsd keyboard layouts)" -gt 80 ] && echo yes || echo no)"
check "dragonfly: the keymaps of DragonFly (more than 40)" yes "$([ "$(count dragonfly keyboard layouts)" -gt 40 ] && echo yes || echo no)"
check "illumos: the keymaps of the captured kbd_layouts (47 and the default)" yes \
	"$([ "$(count illumos keyboard layouts)" -ge 47 ] && echo yes || echo no)"
for os in netbsd openbsd; do
	check "${os}: the wscons encodings (more than 20)" yes "$([ "$(count "${os}" keyboard layouts)" -gt 20 ] && echo yes || echo no)"
done

# A real system whose zone table cannot be read: every zone, and a warning.
rc=0
out=$(env -u INSTALLER_ADAPTER_FIXTURE INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ZONEINFO="${tmp}/none" \
	"${backend}" timezone probe 2>"${tmp}/tz.err") || rc=$?
check "no zone table: every zone of the installer's table" "${zones}" \
	"$(printf '%s' "${out}" | python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)["zones"]))')"
check_contains "no zone table: a warning for the log" "warning: the zone table of the system cannot be read" \
	"$(cat "${tmp}/tz.err")"
out=$(env -u INSTALLER_ADAPTER_FIXTURE INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_KEYMAP_DIR="${tmp}/none" \
	"${backend}" keyboard probe 2>"${tmp}/kb.err") || :
check_contains "no keymap directory: a warning for the log" "warning: the keymaps of the system" "$(cat "${tmp}/kb.err")"

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 73) % 400) + 3900 ))
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

cat > "${tmp}/spec.json" <<'JSON'
[{"name": "tz", "page": "timezone", "full": false, "state": {"report": "lists_and_eyes", "search": "berlin"}},
 {"name": "users", "page": "users", "full": false, "state": {"report": "lists_and_eyes", "reveal": "password"}},
 {"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "lists_and_eyes", "reveal": "pass1"}}]
JSON
mkdir -p "${tmp}/shots"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
	bin/installer-gui --render "${tmp}/spec.json" --size 1024x768 --screenshots "${tmp}/shots" \
	> "${tmp}/render.log" 2>&1 || cat "${tmp}/render.log" >&2
r() {
	python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/shots/$1.lists_and_eyes.json" "$2" 2>&1
}
check "time zone page: every zone in the list" "${zones}" "$(r tz 'r["zones"]')"
check "time zone page: the search filters (berlin)" "['Europe/Berlin']" "$(r tz 'r["filtered"]')"
check "time zone page: the list scrolls in its own scroller" True "$(r tz 'r["zones_scroll"]')"
check "users: every password field has its eye" \
	"{'password': True, 'confirm': True, 'root_pw': True, 'root_pw2': True}" "$(r users 'r["eyes"]')"
check "users: the eye shows that field only" "{'password': True, 'confirm': False, 'root_pw': False, 'root_pw2': False}" \
	"$(r users 'r["shown"]')"
check "users: the eye has a name for a screen reader" "Show the password" "$(r users 'r["eye_name"]')"
check "users: leaving the page hides it again" False "$(r users 'r["shown_after_leaving"]')"
check "disk: the passphrase fields have their eye, one shown" "{'pass1': True, 'pass2': False}" \
	"$(r disk 'r["shown"]')"

finish

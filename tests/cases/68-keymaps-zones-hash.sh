#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The keyboard layouts and the time zones come from the adapter of the
# system (its keymap directory or list, and the zone table of zoneinfo), and
# the sections offer and accept exactly those.  The adapter names the crypt
# scheme of its system and the users section passes it on.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-lists.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"

conf() {
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\n' "$1" > "${tmp}/$1.conf"
	printf 'DEFAULT_KEYMAP=%s\nDEFAULT_TZ=UTC\n' "${2:-us}" >> "${tmp}/$1.conf"
}

names() {
	printf '%s' "$1" | python3 -I -c '
import json, sys
print(" ".join(i["name"] for i in json.load(sys.stdin)[sys.argv[1]]))' "$2"
}

# A zoneinfo directory with a zone table of three zones.
mkdir -p "${tmp}/zoneinfo"
printf '# comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\nJP\t+353916+1394441\tAsia/Tokyo\nUS\t+404251-0740023\tAmerica/New_York\tEastern (most areas)\n' \
	> "${tmp}/zoneinfo/zone1970.tab"
# A vt keymap directory.
mkdir -p "${tmp}/vt"
for k in us uk de fr.acc; do : > "${tmp}/vt/${k}.kbd"; done

export INSTALLER_ZONEINFO="${tmp}/zoneinfo" INSTALLER_KEYMAP_DIR="${tmp}/vt"

conf freebsd
out=$(INSTALLER_CONF="${tmp}/freebsd.conf" "${backend}" timezone probe)
check "the zones are the zone table, UTC first" \
	"UTC America/New_York Asia/Tokyo Europe/Berlin" "$(names "${out}" zones)"
check_contains "the zone table comment is the description" "most of Germany" "${out}"
out=$(INSTALLER_CONF="${tmp}/freebsd.conf" "${backend}" keyboard probe)
check "freebsd: the layouts are the vt keymaps" "de fr.acc uk us" "$(names "${out}" layouts)"

printf 'KEYMAP=fr.acc\nTIMEZONE=Asia/Tokyo\n' > "${tmp}/answers"
rc=0
INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" keyboard validate >/dev/null 2>&1 || rc=$?
check_rc "a layout of the system is accepted" 0 "${rc}"
rc=0
INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" timezone validate >/dev/null 2>&1 || rc=$?
check_rc "a zone of the zone table is accepted" 0 "${rc}"
printf 'KEYMAP=gb\nTIMEZONE=Europe/London\n' > "${tmp}/answers"
rc=0
INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" keyboard validate >/dev/null 2>&1 || rc=$?
check_rc "a layout the system does not have is refused" 2 "${rc}"
rc=0
INSTALLER_CONF="${tmp}/freebsd.conf" INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" timezone validate >/dev/null 2>&1 || rc=$?
check_rc "a zone the table does not have is refused" 2 "${rc}"

# Without the keymap directory, the adapter has a list of its own.
out=$(INSTALLER_KEYMAP_DIR="${tmp}/none" INSTALLER_CONF="${tmp}/freebsd.conf" \
	"${backend}" keyboard probe)
check_contains "freebsd: without a keymap directory the common layouts" '"name":"uk"' "${out}"

conf netbsd
out=$(INSTALLER_CONF="${tmp}/netbsd.conf" "${backend}" keyboard probe)
check_contains "netbsd: the wscons encodings (Swiss German)" \
	'{"name":"sg","descr":"Switzerland (German)"}' "${out}"
conf dragonfly us.iso
out=$(INSTALLER_KEYMAP_DIR="${tmp}/none" INSTALLER_CONF="${tmp}/dragonfly.conf" \
	"${backend}" keyboard probe)
check_contains "dragonfly: the syscons keymaps" '"name":"german.iso"' "${out}"

# The crypt scheme of every system.
for pair in freebsd:sha512 dragonfly:sha512 netbsd:bcrypt-2a openbsd:bcrypt illumos:sha512; do
	os=${pair%%:*}
	conf "${os}"
	out=$(INSTALLER_CONF="${tmp}/${os}.conf" "${backend}" users probe)
	check_contains "${os}: the users probe names the crypt scheme" \
		"\"hash_scheme\":\"${pair#*:}\"" "${out}"
done

# A rehearsal keeps the short lists of the sections, so that a rehearsal
# looks the same on every machine.
out=$(INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
	INSTALLER_CONF="${tmp}/freebsd.conf" "${backend}" keyboard probe)
check "a rehearsal offers the layouts of the section" "us gb de fr es" "$(names "${out}" layouts)"

finish

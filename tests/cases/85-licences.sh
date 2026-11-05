#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The optional licensed software: the catalogue is read strictly, the root
# helper checks the accepted ids against the catalogue on the media, writes
# the record of acceptance (0600 JSON: id, licence, sha256 of the text,
# time) and gives it to the install command with -l.  Nothing is accepted
# unless the answers say so.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-licences.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

helper="${root}/bin/installer-apply"
stubs="${root}/tests/stubs"
fixture="${root}/tests/fixtures/adapter-fixture-software.conf"
catalogue="${root}/tests/fixtures/software/licensed-software.json"

out=$(INSTALLER_ADAPTER_FIXTURE="${fixture}" "${helper}" --list software)
check_contains "--list software gives the catalogue" '"id":"example-gpu-driver"' "${out}"

submit() { # submit <ACCEPT_LICENSES value or nothing>
	rm -rf "${tmp}/s"
	mkdir -m 700 "${tmp}/s"
	printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${tmp}/s/user.hash"
	{
		printf 'KEYMAP=us\nTIMEZONE=UTC\nDISK=ada0\nUSER_NAME=tester\nUSER_AUTH=password\nNETWORK_MODE=offline\n'
		[ -z "${1:-}" ] || printf 'ACCEPT_LICENSES=%s\n' "$1"
	} > "${tmp}/s/answers.conf"
	chmod 600 "${tmp}/s/answers.conf"
}
# Without a rehearsal: the real path through the install command.
cat > "${tmp}/norehearsal.conf" <<CONF
PRODUCT_NAME=ExampleBSD
PRODUCT_SLUG=examplebsd
OS=freebsd
DEFAULT_KEYMAP=us
DEFAULT_TZ=UTC
CONF
real_install() {
	rm -f "${tmp}/args" "${tmp}/accept"
	rc=0
	out=$(env PATH="${stubs}:${PATH}" STUB_MOUNTS="${tmp}/mounts" STUB_DISKS='ada0 ada1' \
		STUB_DISK_INFO="${tmp}/disk-info" STUB_INTERFACES='em0' \
		STUB_INSTALL_ARGS="${tmp}/args" STUB_INSTALL_ACCEPT_COPY="${tmp}/accept" \
		INSTALLER_CONF="${tmp}/norehearsal.conf" \
		"${helper}" --install "${tmp}/s" < /dev/null 2>&1) || rc=$?
}
printf 'ada0\tExample SSD\t500107862016\nada1\tExample SSD\t500107862016\n' > "${tmp}/disk-info"
printf '/dev/ada9p3 / ufs rw 0 0\n' > "${tmp}/mounts"
# The catalogue of a real system is in the licences directory of the
# installer: a copy of the tree carries the fixture there.
tree="${tmp}/tree"
mkdir -p "${tree}"
cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" "${root}/installer.conf" "${tree}/"
mkdir -p "${tree}/licences"
cp -R "${root}/tests/fixtures/software/." "${tree}/licences/"
helper="${tree}/bin/installer-apply"

submit 'example-gpu-driver,example-display-font'
real_install
check_rc "the install runs with the accepted licences" 0 "${rc}"
args=$(cat "${tmp}/args" 2>/dev/null || true)
check_contains "the install command gets -l" "-l" "${args}"
record=$(cat "${tmp}/accept" 2>/dev/null || true)
check "the record names exactly the accepted items, in the order of the catalogue" \
	"example-gpu-driver example-display-font" \
	"$(printf '%s' "${record}" | python3 -I -B -c 'import json,sys; print(" ".join(e["id"] for e in json.load(sys.stdin)))')"
want=$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
	"${root}/tests/fixtures/software/licences/example-gpu-eula.txt")
check_contains "the record holds the sha256 of the licence text" "${want}" "${record}"
check_contains "the record holds the time of acceptance" '"accepted_at"' "${record}"

submit 'example-gpu-driver,example-not-there'
real_install
check_rc "an id that is not in the catalogue is refused" 2 "${rc}"
check "and the install command never ran" no "$([ -f "${tmp}/args" ] && echo yes || echo no)"
check_contains "it says which" "example-not-there" "${out}"

submit 'example-gpu-driver;id'
real_install
check_rc "an answer that is not a list of ids is refused" 2 "${rc}"

submit ''
real_install
check_rc "nothing accepted: the install runs" 0 "${rc}"
check_absent "nothing accepted: no -l" "-l" "$(cat "${tmp}/args" 2>/dev/null || true)"

finish

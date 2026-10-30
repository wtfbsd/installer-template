#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The dispatcher contract: bad input exits 2, a missing adapter exits 3 and a
# section probe prints JSON.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

backend="${root}/bin/installer-backend"

rc=0
out=$("${backend}" no-such-section probe 2>&1) || rc=$?
check_rc "an unknown section exits 2" 2 "${rc}"
check_contains "an unknown section is named" "no-such-section" "${out}"

rc=0
out=$("${backend}" welcome sideways 2>&1) || rc=$?
check_rc "an unknown verb exits 2" 2 "${rc}"
check_contains "an unknown verb is named" "sideways" "${out}"

rc=0
out=$("${backend}" Disk probe 2>&1) || rc=$?
check_rc "a section name with an upper case letter exits 2" 2 "${rc}"

rc=0
out=$("${backend}" 1disk probe 2>&1) || rc=$?
check_rc "a section name that starts with a digit exits 2" 2 "${rc}"

rc=0
out=$("${backend}" disk sideways 2>&1) || rc=$?
check_rc "a bad verb on a real section exits 2" 2 "${rc}"

rc=0
out=$(INSTALLER_CONF="${root}/tests/fixtures/installer-netbsd.conf" \
	"${backend}" disk probe 2>&1) || rc=$?
check_rc "an adapter that is not implemented exits 3" 3 "${rc}"
check_contains "the missing adapter names the system" \
	"adapter not implemented for netbsd" "${out}"

# Every adapter that is not written yet has to report the gap and exit 3.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-adapters.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

for system in openbsd dragonfly illumos netbsd; do
	conf="${tmp}/${system}.conf"
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\n' \
		"${system}" > "${conf}"
	printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' >> "${conf}"
	rc=0
	out=$(INSTALLER_CONF="${conf}" "${backend}" disk probe 2>&1) || rc=$?
	check_rc "the ${system} adapter that is not written exits 3" 3 "${rc}"
	check_contains "the ${system} adapter names the system" \
		"adapter not implemented for ${system}" "${out}"
done

rc=0
out=$("${backend}" welcome probe 2>&1) || rc=$?
check_rc "the welcome section probes" 0 "${rc}"

rc=0
printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' || rc=$?
check_rc "the welcome probe prints JSON" 0 "${rc}"

check_contains "the probe names the product" '"product":"ExampleBSD"' "${out}"
check_contains "the probe names the section" '"section":"welcome"' "${out}"

finish

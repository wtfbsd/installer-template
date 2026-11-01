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
out=$(INSTALLER_CONF="${root}/tests/fixtures/installer-illumos.conf" \
	"${backend}" disk probe 2>&1) || rc=$?
check_rc "an adapter that is not implemented exits 3" 3 "${rc}"
check_contains "the missing adapter names the system" \
	"adapter not implemented for illumos" "${out}"

# Every adapter that is not written yet has to report the gap and exit 3.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-adapters.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

for system in illumos; do
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

# The adapters that are written answer every operation of the contract
# that only reads, and never report a gap.
for system in freebsd netbsd openbsd dragonfly; do
	conf="${tmp}/${system}.conf"
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\n' \
		"${system}" > "${conf}"
	printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' >> "${conf}"
	for section in disk network keyboard timezone users; do
		rc=0
		out=$(INSTALLER_CONF="${conf}" "${backend}" "${section}" probe 2>&1) || rc=$?
		check_rc "the ${system} adapter answers the ${section} probe" 0 "${rc}"
		check_absent "the ${system} adapter is written (${section})" \
			"not implemented" "${out}"
	done
done

# illumos is written against the documented formats and is unproven: on a
# machine it reports the gap (above); in a rehearsal it answers every
# operation that only reads.
for section in disk network keyboard timezone users; do
	rc=0
	out=$(INSTALLER_CONF="${root}/tests/fixtures/installer-illumos.conf" \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
		"${backend}" "${section}" probe 2>&1) || rc=$?
	check_rc "the illumos adapter answers the ${section} probe in a rehearsal" 0 "${rc}"
done
out=$(INSTALLER_CONF="${root}/tests/fixtures/installer-illumos.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
	"${backend}" disk probe 2>&1) || :
check_contains "illumos offers the ZFS layouts" '"ident":"raidz2"' "$(printf '%s' "${out}" | tr -d ' ')"

rc=0
out=$("${backend}" welcome probe 2>&1) || rc=$?
check_rc "the welcome section probes" 0 "${rc}"

rc=0
printf '%s' "${out}" | python3 -I -c 'import json,sys; json.load(sys.stdin)' || rc=$?
check_rc "the welcome probe prints JSON" 0 "${rc}"

check_contains "the probe names the product" '"product":"ExampleBSD"' "${out}"
check_contains "the probe names the section" '"section":"welcome"' "${out}"

finish

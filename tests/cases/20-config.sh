#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The configuration is parsed, never sourced.  A value that tries to run a
# command is rejected and never runs.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

config="${root}/bin/installer-config"

rc=0
out=$("${config}" get PRODUCT_NAME 2>&1) || rc=$?
check_rc "the product name is read" 0 "${rc}"
check "the product name is the placeholder" "ExampleBSD" "${out}"

rc=0
out=$("${config}" get OS 2>&1) || rc=$?
check_rc "the operating system is read" 0 "${rc}"
check "the operating system is the placeholder" "freebsd" "${out}"

rc=0
out=$("${config}" validate 2>&1) || rc=$?
check_rc "the shipped configuration is valid" 0 "${rc}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-config.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

cp "${root}/tests/fixtures/installer-eval.conf" "${tmp}/installer.conf"
rc=0
out=$(cd "${tmp}" && INSTALLER_CONF="${tmp}/installer.conf" "${config}" validate 2>&1) || rc=$?
check_rc "a value with command substitution is rejected" 2 "${rc}"
check_contains "the rejected key is named" "PRODUCT_NAME" "${out}"

if [ -e "${tmp}/pwned" ]; then
	printf 'FAIL the configuration value was executed\n'
	fails=$((fails + 1))
else
	printf 'ok   the configuration value was not executed\n'
fi

printf 'PRODUCT_NAME=ExampleBSD\nBOGUS_KEY=1\n' > "${tmp}/bogus.conf"
rc=0
out=$(INSTALLER_CONF="${tmp}/bogus.conf" "${config}" validate 2>&1) || rc=$?
check_rc "an unknown key is rejected" 2 "${rc}"
check_contains "the unknown key is named" "BOGUS_KEY" "${out}"

printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_NAME=Other\n' > "${tmp}/twice.conf"
rc=0
out=$(INSTALLER_CONF="${tmp}/twice.conf" "${config}" validate 2>&1) || rc=$?
check_rc "a duplicated key is rejected" 2 "${rc}"

finish

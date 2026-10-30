#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# run-tests: the installer test suite.  It runs every case under tests/cases
# and then the Python unit tests.  No root, no network, no virtual machine.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
cd "${root}"

pass=0
fail=0

for case_script in "${here}"/cases/*.sh; do
	name=$(basename "${case_script}" .sh)
	if sh "${case_script}"; then
		printf 'ok   %s\n' "${name}"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n' "${name}"
		fail=$((fail + 1))
	fi
done

if python3 -m unittest discover -s tests -p 'test_*.py'; then
	printf 'ok   python-unittest\n'
	pass=$((pass + 1))
else
	printf 'FAIL python-unittest\n'
	fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]

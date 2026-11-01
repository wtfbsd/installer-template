#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# run-tests: the installer test suite.  It runs every case under tests/cases
# and then the Python unit tests.  No root, no network, no virtual machine.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
cd "${root}"
. "${here}/lib.sh"

# Every case and every unit test runs with a TMPDIR of the suite's own
# (mode 0700, made by mktemp -d), so two suites that run at the same time
# never see each other's files, and nothing is left in the shared one.
suite_parent=${TMPDIR:-/tmp}
suite_tmp=$(mktemp -d "${suite_parent}/wtfbsd-tests.XXXXXX")
chmod 700 "${suite_tmp}"
trap 'chmod -R u+rwX "${suite_tmp}" 2>/dev/null || :; rmrf "${suite_tmp}" "${suite_parent}" || :' EXIT INT TERM HUP
TMPDIR=${suite_tmp}
export TMPDIR

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

if python3 -I -m unittest discover -s tests -p 'test_*.py'; then
	printf 'ok   python-unittest\n'
	pass=$((pass + 1))
else
	printf 'FAIL python-unittest\n'
	fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]

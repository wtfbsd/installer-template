#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The documentation of the repository says what the repository does: the
# variables of the environment are named, the place of the log is named and
# the case that keeps the names of other people out of the repository is
# named by the file it lives in.  The dead code of the front end is gone.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

# grep_first <file> <pattern> — the first line of the file that holds the
# pattern, or nothing.
grep_first() {
	grep -m1 -- "$2" "$1" 2>/dev/null || true
}

readme="${root}/README.md"
agents="${root}/AGENTS.md"
tui="${root}/bin/installer-tui"

# The test runner is a script and says so on its first line.
check "the test runner names the shell" "#!/bin/sh" \
	"$(head -1 "${root}/tests/run-tests.sh" 2>/dev/null || true)"

# The variables of the environment are documented.
check_contains "the README has a section about the environment" \
	"## Environment" "$(grep_first "${readme}" '## Environment')"
for name in INSTALLER_CONF INSTALLER_ROOT INSTALLER_LIBEXEC BSDDIALOG \
	INSTALLER_LOG; do
	check_contains "the README documents ${name}" "${name}" \
		"$(grep_first "${readme}" "${name}")"
done

# The log of a run is kept next to the state directory of the run.
check_contains "the README says where the log is kept" \
	"parent directory of the state" \
	"$(grep_first "${readme}" 'parent directory of the state')"

# The case that keeps the names of other people out of the repository is
# named by the file it lives in.
check_contains "the README names the case that looks for names" \
	"tests/cases/60-no-internal-refs.sh" \
	"$(grep_first "${readme}" 'tests/cases/60-no-internal-refs.sh')"
check_contains "the agents file names the case that looks for names" \
	"tests/cases/60-no-internal-refs.sh" \
	"$(grep_first "${agents}" 'tests/cases/60-no-internal-refs.sh')"

# The dead code of the front end is gone.
check_absent "the front end has no variable it does not use" \
	'slug=$(config_value' "$(grep_first "${tui}" 'slug=' || true)"
check_absent "the front end has no variable it does not use" \
	'system=$(config_value' "$(grep_first "${tui}" 'system=' || true)"
check_absent "the front end makes no fifo" "mkfifo" \
	"$(grep_first "${tui}" 'mkfifo' || true)"
check_absent "the front end names no fifo" "gauge.fifo" \
	"$(grep_first "${tui}" 'gauge.fifo' || true)"

finish

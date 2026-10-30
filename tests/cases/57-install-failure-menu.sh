#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The page that follows a failed installation offers the retry first: it is
# the choice that Enter accepts and the sentence of the page names it
# first.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-failure.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture-fail.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-fail.txt"

if [ "${tui_rc}" -ne 0 ]; then
	printf 'ok   the installer ends with a non zero code after a failure\n'
else
	printf 'FAIL the installer ended with %s after a failure\n' "${tui_rc}"
	fails=$((fails + 1))
fi

log="${BSDDIALOG_LOG}"

failure=$(awk -F'\t' '/^CALL/ && /The installation did not finish/ { print }' "${log}")
if [ -n "${failure}" ]; then
	printf 'ok   the failure page was shown\n'
else
	printf 'FAIL the failure page was not shown\n'
	fails=$((fails + 1))
fi

# The items of the menu are the last four fields of the call.
items=$(printf '%s\n' "${failure}" |
	awk -F'\t' '{ n = NF; print $(n - 3) "\t" $(n - 1) }')
check "the failure page offers the retry first" "Retry	Back" "${items}"

check_contains "the sentence of the failure page names the retry first" \
	"Choose Retry to run the installation again, or Back to return to the summary." \
	"${failure}"

finish

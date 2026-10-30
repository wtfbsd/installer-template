#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A failed installation never reaches the finished page: the failure page
# offers to run the installation again or to go back to the summary, the
# details go to the log and leaving the installer after a failure ends with a
# non zero exit code.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-fail.XXXXXX")
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

dialog_log=$(cat "${BSDDIALOG_LOG}")
check_absent "nothing claims that the system is installed" \
	"is installed" "${dialog_log}"
check_contains "the failure page is shown" \
	"The installation did not finish" "${dialog_log}"
check_contains "the failure page offers to run it again" \
	"Retry" "${dialog_log}"
check_contains "the failure page offers to go back" \
	"Back" "${dialog_log}"

log_size=$(wc -c < "${INSTALLER_LOG}" 2>/dev/null || printf 0)
if [ "${log_size}" -gt 0 ]; then
	printf 'ok   the log holds the output of the backend\n'
else
	printf 'FAIL the log is empty\n'
	fails=$((fails + 1))
fi
check_contains "the log holds the output of the backend" \
	"install: writing the system files" "$(cat "${INSTALLER_LOG}")"

finish

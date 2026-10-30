#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The escape key asks whether to leave the installer.  Only an answer of yes
# leaves: every other answer brings the same dialog back and the run goes
# on.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-escape.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-escape.txt"
check_rc "the run goes on when the user does not want to quit" 0 "${tui_rc}"

dialog_log=$(cat "${BSDDIALOG_LOG}")
check_contains "the escape key asks whether to quit" \
	"Quit the installer?" "${dialog_log}"
check_contains "the run reaches the finished page" \
	"is installed" "${dialog_log}"
check_contains "the keyboard layout was chosen" \
	"USER_NAME=tester" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"

finish

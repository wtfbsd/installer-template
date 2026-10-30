#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# When the hardware could not be read, the screen before the first page says
# why: the message of the backend is shown next to what was detected.  The
# message is in the log as well.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-probe.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# The adapter of this system is not written yet, so the backend says so.
INSTALLER_CONF="${root}/tests/fixtures/installer-netbsd.conf"
export INSTALLER_CONF

tui_run "${root}/tests/fixtures/answers-nodisk.txt"

dialog_log=$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)
check_contains "the screen says why the hardware could not be read" \
	"adapter not implemented for netbsd" "${dialog_log}"
check_contains "the screen still says what was detected" \
	"Detected:" "${dialog_log}"

log_text=$(cat "${INSTALLER_LOG}" 2>/dev/null || true)
check_contains "the log holds the message of the backend" \
	"adapter not implemented for netbsd" "${log_text}"

finish

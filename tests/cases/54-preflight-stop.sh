#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A run that cannot go on before the first page says so: the reason is
# written to standard error and the run ends with a non zero code.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-stop.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${tmp}/empty-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A machine without a disk.
printf 'DISKS=\nINTERFACES=em0\n' > "${INSTALLER_ADAPTER_FIXTURE}"

rm -f "${BSDDIALOG_LOG}" "${BSDDIALOG_STATE}"
rc=0
BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-nodisk-cancel.txt" \
	"${root}/bin/installer-tui" > "${tmp}/out.txt" 2> "${tmp}/err.txt" || rc=$?

if [ "${rc}" -ne 0 ]; then
	printf 'ok   the run ends with a non zero code\n'
else
	printf 'FAIL the run ended with 0\n'
	fails=$((fails + 1))
fi

err=$(cat "${tmp}/err.txt" 2>/dev/null || true)
check_contains "the run says that it stopped before the first page" \
	"the installer stopped before the first page" "${err}"
check_contains "the run says why it stopped" "A disk to install to" "${err}"
check_contains "the run says to run it again" "run it again" "${err}"

# The first page is never reached and nothing is installed.
dialog_log=$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)
check_absent "the first page is never reached" "[Keyboard]" "${dialog_log}"
check_absent "nothing was installed" "is installed" "${dialog_log}"

finish

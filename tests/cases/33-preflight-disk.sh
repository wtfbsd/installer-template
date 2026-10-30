#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The checks that run before the first page: a machine without a disk is
# told so before the first page and the choice to look again looks for the
# hardware anew.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-preflight.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

stubs="${root}/tests/stubs"

cat > "${tmp}/disk-info" <<'DISKS'
ada0	Samsung SSD 860	500107862016
DISKS

# The running system is on a disk of its own, so the disk that shows up
# later is free.
printf '/dev/ada1p3 / ufs rw 0 0\n' > "${tmp}/mounts"

# A machine without a disk: the screen before the first page says so.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${tmp}/empty-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG
printf 'DISKS=\nINTERFACES=em0\n' > "${INSTALLER_ADAPTER_FIXTURE}"

tui_run "${root}/tests/fixtures/answers-nodisk.txt"
check_rc "the installer leaves without installing when there is no disk" \
	0 "${tui_rc}"

dialog_log=$(cat "${BSDDIALOG_LOG}")
check_contains "the screen before the first page names the disk" \
	"A disk to install to" "${dialog_log}"
check_contains "the screen before the first page says that no disk was found" \
	"none found" "${dialog_log}"
check_contains "the screen before the first page offers to look again" \
	"Rescan" "${dialog_log}"
check_contains "the screen before the first page offers to stay in the live system" \
	"Stay in the live system" "${dialog_log}"
check_absent "the first page is never reached" "[Keyboard]" "${dialog_log}"
check_absent "nothing was installed" "is installed" "${dialog_log}"

# A machine whose disk shows up after the first look: the choice to look
# again looks for the hardware anew and the run goes on.
rm -f "${BSDDIALOG_LOG}" "${BSDDIALOG_STATE}"
unset INSTALLER_ADAPTER_FIXTURE
rc=0
out=$(PATH="${stubs}:${PATH}" \
	STUB_DISKS='' \
	STUB_DISKS_LATER='ada0' \
	STUB_DISKS_AFTER=2 \
	STUB_STATE="${tmp}/sysctl.calls" \
	STUB_DISK_INFO="${tmp}/disk-info" \
	STUB_MOUNTS="${tmp}/mounts" \
	STUB_INTERFACES='em0' \
	BSDDIALOG_LOG="${BSDDIALOG_LOG}" \
	BSDDIALOG_STATE="${BSDDIALOG_STATE}" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-rescan.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

dialog_log=$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)
check_contains "the screen before the first page says that no disk was found" \
	"A disk to install to" "${dialog_log}"
check_contains "the run goes on after the hardware was looked for again" \
	"[Keyboard]" "${dialog_log}"

# The screen before the first page comes before the first page.
order=$(sed -n 's/.*\[\([^][]*\)\].*/\1/p' "${BSDDIALOG_LOG}" |
	awk 'NF && $0 != previous { print; previous = $0 }' | tr '\n' ' ')
check "the screen comes before the first page" \
	"Unfortunately Welcome Keyboard Timezone Disk " "${order}"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The disk that is chosen is the disk that is written to: the name has to
# match one of the disks of the machine exactly, the summary says what is
# going to be erased and the front end checks the choice before it starts.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-disk.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
export INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"

answers="${tmp}/answers.conf"

validate_disk() { # validate_disk <disk> — the exit code of the disk check
	printf 'DISK=%s\n' "$1" > "${answers}"
	rc=0
	INSTALLER_ANSWERS="${answers}" "${backend}" disk validate >/dev/null 2>&1 || rc=$?
	printf '%s\n' "${rc}"
}

check_rc "a disk of the machine is accepted" 0 "$(validate_disk ada0)"
check_rc "the description of a disk is not a disk" 2 "$(validate_disk descr)"
check_rc "a name that carries a description is not a disk" 2 \
	"$(validate_disk 'ada0","descr":"ada0')"
check_rc "a name that is not a disk is refused" 2 "$(validate_disk disk)"

# The text of the hardware is reduced to printable ASCII without a quote and
# without a backslash before it is put in the JSON.
printf 'DISKS=ada0|Sa"msu\\ng SSD|100\nINTERFACES=\n' > "${tmp}/odd.conf"
probe=$(INSTALLER_ADAPTER_FIXTURE="${tmp}/odd.conf" \
	"${backend}" disk probe 2>/dev/null) || probe=''
check_contains "the disk list is still JSON" '"name":"ada0"' "${probe}"
printf '%s' "${probe}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
descr = data["disks"][0]["descr"]
assert chr(34) not in descr, descr
assert chr(92) not in descr, descr
assert all(32 <= ord(c) <= 126 for c in descr), descr
' || fails=$((fails + 1))

# The summary says which disk is going to be erased.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"
check_contains "the summary names the disk that is erased" \
	"This will erase ada0" "$(cat "${BSDDIALOG_LOG}")"
check_contains "the summary describes the disk" \
	"Samsung SSD 860" "$(cat "${BSDDIALOG_LOG}")"

# The front end checks the chosen disk before it installs anything: the log
# holds the answer of the backend before the output of the installation.
checked=$(grep -n 'may be written to' "${INSTALLER_LOG}" |
	head -1 | cut -d: -f1)
started=$(grep -n 'install: preparing the target disk' "${INSTALLER_LOG}" |
	head -1 | cut -d: -f1)
if [ -n "${checked}" ] && [ -n "${started}" ] &&
	[ "${checked}" -lt "${started}" ]; then
	printf 'ok   the front end checks the disk before it installs\n'
else
	printf 'FAIL the front end does not check the disk before it installs\n'
	fails=$((fails + 1))
fi

finish

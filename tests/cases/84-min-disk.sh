#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The smallest disk: the setting MIN_DISK_GB of installer.conf (16 when it
# is not set), but never less than what the media needs: the size of the
# installed image (the adapter verb image-size), 2 GB to spare and the swap.
# The root helper refuses a smaller disk and says what the minimum is and
# why.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-min-disk.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

conf() { # conf <MIN_DISK_GB or empty>
	sed '/^MIN_DISK_GB=/d' installer.conf > "${tmp}/installer.conf"
	[ -z "$1" ] || printf 'MIN_DISK_GB=%s\n' "$1" >> "${tmp}/installer.conf"
}
fixture() { # fixture <image bytes>
	cat > "${tmp}/fixture.conf" <<CONF
DISKS=ada0|Example SSD 12GB|12884901888
INTERFACES=em0|Example Gigabit Ethernet
IMAGE_SIZE=$1
CONF
}
requirements() {
	INSTALLER_CONF="${tmp}/installer.conf" INSTALLER_ADAPTER_FIXTURE="${tmp}/fixture.conf" \
		bin/installer-apply --list disks | python3 -I -c '
import json, sys
r = json.load(sys.stdin)["detail"]["requirements"]
print(r["min_disk_gb"], r["image_bytes"])'
}

conf ''
fixture 4294967296
check "without the setting the minimum is 16 GB" "16 4294967296" "$(requirements)"
conf 8
check "the setting reaches the disk report" "8 4294967296" "$(requirements)"
for bad in 0 -3 abc 99999 1.5; do
	conf "${bad}"
	INSTALLER_CONF="${tmp}/installer.conf" bin/installer-config validate >/dev/null 2>&1 && rc=0 || rc=$?
	check_rc "MIN_DISK_GB=${bad} is refused" 2 "${rc}"
done

# The text front end on a 12 GB disk, through the root helper.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
INSTALLER_CONF="${tmp}/installer.conf"
INSTALLER_ADAPTER_FIXTURE="${tmp}/fixture.conf"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_STATE_PARENT INSTALLER_ANSWERS
export INSTALLER_LOG INSTALLER_CONF INSTALLER_ADAPTER_FIXTURE

# MIN_DISK_GB=8 and a 4 GB image: 12 GB is enough.
conf 8
fixture 4294967296
tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "a 12 GB disk passes the setting of 8 GB" 0 "${tui_rc}"

# The default of 16 GB refuses it, and says so.
conf ''
: > "${INSTALLER_LOG}"
tui_run "${root}/tests/fixtures/answers-happy.txt"
[ "${tui_rc}" -ne 0 ] && refused=yes || refused=no
check "the default minimum refuses a 12 GB disk" yes "${refused}"
check_contains "the refusal says the minimum and why" \
	"is smaller than the 16 GB the system needs (the setting MIN_DISK_GB of this media)" \
	"$(cat "${INSTALLER_LOG}" "${BSDDIALOG_LOG}" 2>/dev/null)"

# A setting of 8 GB but an image of 11 GB: never below the media.
conf 8
fixture 11811160064
: > "${INSTALLER_LOG}"
tui_run "${root}/tests/fixtures/answers-happy.txt"
[ "${tui_rc}" -ne 0 ] && refused=yes || refused=no
check "the size of the image wins over a lower setting" yes "${refused}"
check_contains "the refusal names the image" \
	"is smaller than the 13 GB the system needs (the system image takes 11 GB, plus 2 GB to spare and 0 MB of swap)" \
	"$(cat "${INSTALLER_LOG}" "${BSDDIALOG_LOG}" 2>/dev/null)"

finish

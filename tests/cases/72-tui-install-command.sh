#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text front end on a machine (no rehearsal): the FreeBSD adapter reads
# the hardware through the stand-ins of the tools and runs the install
# command of the template.  The install command gets a crypt hash of the
# password in a file of mode 0600, never the password, and the gauge shows
# the PROGRESS lines of the install command.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-tui-install.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

printf 'ada0\tSamsung SSD 860\t500107862016\n' > "${tmp}/disk-info"
printf '/dev/ada1p3 / ufs rw 0 0\n' > "${tmp}/mounts"

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
BSDDIALOG_GAUGE_LOG="${tmp}/gauge.log"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
PATH="${root}/tests/stubs:${PATH}"
STUB_DISKS='ada0 ada1'
STUB_DISK_INFO="${tmp}/disk-info"
STUB_MOUNTS="${tmp}/mounts"
STUB_INTERFACES='em0'
STUB_INSTALL_ARGS="${tmp}/args"
STUB_INSTALL_HASH_COPY="${tmp}/hash"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE BSDDIALOG_GAUGE_LOG
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG PATH
export STUB_DISKS STUB_DISK_INFO STUB_MOUNTS STUB_INTERFACES
export STUB_INSTALL_ARGS STUB_INSTALL_HASH_COPY
unset INSTALLER_ADAPTER_FIXTURE INSTALLER_CONF 2>/dev/null || :

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the text front end installs with the install command" 0 "${tui_rc}"

hash=$(cat "${tmp}/hash" 2>/dev/null || true)
check_contains "the install command got a SHA-512 crypt hash" '$6$' "${hash}"
ok=$(printf 's3cret-pass\n' | python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[2])
import passhash
pw = sys.stdin.readline().rstrip("\n")
h = open(sys.argv[1]).read().strip()
print("yes" if passhash.sha512_crypt(pw, h) == h else "no")' "${tmp}/hash" "${root}/lib")
check "the hash is the hash of the password typed" yes "${ok}"
check_absent "the password is not an argument of the install command" \
	"s3cret-pass" "$(cat "${tmp}/args" 2>/dev/null || true)"
check_contains "the answers name the hash file" "USER_HASHFILE=" \
	"$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check "the state of the run is gone afterwards" "" \
	"$(find "${tmp}" -name 'user.hash' -print)"

gauge=$(cat "${tmp}/gauge.log" 2>/dev/null || true)
check_contains "the gauge shows the percentage of the install command" \
	"XXX
60
Growing the file system
XXX" "${gauge}"
check_contains "the gauge reaches 100" "XXX
100
Done
XXX" "${gauge}"

# A rehearsal prints a step line after every PROGRESS line: the gauge
# follows the PROGRESS lines and never goes back.
: > "${tmp}/gauge.log"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
	tui_run "${root}/tests/fixtures/answers-happy.txt"
percents=$(awk 'prev == "XXX" && $0 ~ /^[0-9]+$/ { printf "%s ", $0 } { prev = $0 }' "${tmp}/gauge.log")
check "the gauge of a rehearsal follows the PROGRESS lines" \
	"10 10 40 40 70 70 90 90 100 " "${percents}"

# A failure of the install command: the ERROR line reaches the gauge and
# the log, and the run does not reach the finished page.
STUB_INSTALL_FAIL=5
export STUB_INSTALL_FAIL
: > "${tmp}/gauge.log"
tui_run "${root}/tests/fixtures/answers-fail.txt"
check_contains "the error of the install command is on the gauge" \
	"the disk ada0 could not be written" "$(cat "${tmp}/gauge.log")"
check_contains "the error of the install command is in the log" \
	"ERROR the disk ada0 could not be written" "$(cat "${INSTALLER_LOG}" 2>/dev/null || true)"
check_absent "a failed installation never reaches the finished page" \
	"is installed" "$(cat "${BSDDIALOG_LOG}")"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text front end: the pages appear in the documented order, the answers
# are gated before they are written, the choice of the user is read from the
# output descriptor of the dialog tool and a machine without a disk is not a
# dead end.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-tui.XXXXXX")
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

pages_of() { # pages_of <log> — the page tags in order, without repeats
	sed -n 's/.*\[\([^][]*\)\].*/\1/p' "$1" |
		awk 'NF && $0 != previous { print; previous = $0 }' |
		tr '\n' ' '
}

answers_text() { # answers_text — the answers the front end wrote
	cat "${INSTALLER_ANSWERS}" 2>/dev/null || true
}

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"

check "the pages appear in the documented order" \
	"Welcome Keyboard Timezone Disk Users Network Summary Install Finish " \
	"$(pages_of "${BSDDIALOG_LOG}")"

answer_text=$(answers_text)
check_contains "the answers name the user" "USER_NAME=tester" "${answer_text}"
check_contains "the answers name the disk" "DISK=ada0" "${answer_text}"
check_contains "the answers name the network mode" "NETWORK_MODE=dhcp" "${answer_text}"
check_contains "the privilege default asks for a password" \
	"PRIVILEGE_PASSWORDLESS=no" "${answer_text}"
check_contains "the interface is kept in automatic mode" "NET_IF=em0" "${answer_text}"
check_absent "a gated-off address is dropped" "IPV4_ADDR=" "${answer_text}"
check_absent "the screen of the dialog tool is not an answer" \
	"fake screen" "${answer_text}"

secret=$(sed -n 's/^USER_PASSFILE=//p' "${INSTALLER_ANSWERS}")
if [ -n "${secret}" ] && [ ! -e "${secret}" ]; then
	printf 'ok   the user secret is removed after the install\n'
else
	printf 'FAIL the user secret is still there: %s\n' "${secret}"
	fails=$((fails + 1))
fi

tui_run "${root}/tests/fixtures/answers-static.txt"
check_rc "the installer finishes with a manual address" 0 "${tui_rc}"

static_text=$(answers_text)
check_contains "a gated-on interface is kept" "NET_IF=em0" "${static_text}"
check_contains "a gated-on address is kept" "IPV4_ADDR=static-address" "${static_text}"
check_contains "a gated-on netmask is kept" "IPV4_MASK=static-netmask" "${static_text}"
check_contains "a gated-on gateway is kept" "IPV4_GW=static-gateway" "${static_text}"

# A machine without a disk: the screen before the first page says so and
# offers a way out.
INSTALLER_ADAPTER_FIXTURE="${tmp}/empty-fixture.conf"
export INSTALLER_ADAPTER_FIXTURE
printf 'DISKS=\nINTERFACES=em0\n' > "${INSTALLER_ADAPTER_FIXTURE}"
tui_run "${root}/tests/fixtures/answers-nodisk.txt"
check_rc "the installer leaves without installing when there is no disk" 0 "${tui_rc}"
check_contains "the screen before the first page says that no disk was found" \
	"A disk to install to" "$(cat "${BSDDIALOG_LOG}")"
check_contains "the screen before the first page offers a rescan" \
	"Rescan" "$(cat "${BSDDIALOG_LOG}")"
check_contains "the screen before the first page offers to stay in the live system" \
	"Stay in the live system" "$(cat "${BSDDIALOG_LOG}")"
check_absent "the first page is never reached" \
	"[Keyboard]" "$(cat "${BSDDIALOG_LOG}")"
check_absent "nothing was installed" "is installed" "$(cat "${BSDDIALOG_LOG}")"

finish

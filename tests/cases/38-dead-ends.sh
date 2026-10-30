#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installer offers a way out of every dead end: a machine without a
# network adapter can be installed offline, a machine that does not meet a
# requirement can be left in the live system and an override is only offered
# when it can help and only after a confirmation.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-dead.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture-nononet.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A machine without a network adapter: the network page offers to continue
# offline and the choice is written to the answers.
tui_run "${root}/tests/fixtures/answers-offline.txt"
check_rc "the installer finishes without a network" 0 "${tui_rc}"

dialog_log=$(cat "${BSDDIALOG_LOG}")
offline_log=${dialog_log}
check_contains "the network page offers to continue offline" \
	"Continue offline" "${dialog_log}"
check_contains "the network page offers to look again" \
	"Rescan" "${dialog_log}"
check_contains "the answers record the offline choice" \
	"NETWORK_MODE=offline" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check_absent "no interface is recorded when the install is offline" \
	"NET_IF=" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"

# The preflight screen offers to leave the installer without installing.
tui_run "${root}/tests/fixtures/answers-live.txt"
check_rc "the installer leaves without installing" 0 "${tui_rc}"
check_contains "the preflight screen offers to stay in the live system" \
	"Stay in the live system" "$(cat "${BSDDIALOG_LOG}")"
check_absent "nothing was installed" \
	"is installed" "$(cat "${BSDDIALOG_LOG}")"

# An override is only offered when the machine has a disk to install to and
# only after the question is answered with yes.
check_contains "the preflight screen offers an override" \
	"Override" "$(cat "${BSDDIALOG_LOG}")"
check_contains "the override asks for a confirmation" \
	"Continue anyway" "${offline_log}"

finish

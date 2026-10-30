#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The state of an installer run lives in a directory of its own: the
# directory is new, it is private, the secrets in it are private and
# everything is gone when the run ends.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-state.XXXXXX")
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

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"

dialog_log=$(cat "${BSDDIALOG_LOG}")
TAB=$(printf '\t')
check_contains "the state directory is private" "STATE${TAB}700" "${dialog_log}"
check_contains "the secret file is private" \
	"FILE${TAB}secrets/user.pass${TAB}600" "${dialog_log}"

left=$(find "${tmp}" -maxdepth 1 -type d -name 'wtfbsd-installer.*' | wc -l | tr -d ' ')
check "the state directory is gone" "0" "${left}"

# The state directory is new every time: two runs do not share one.
tui_run "${root}/tests/fixtures/answers-happy.txt"
left=$(find "${tmp}" -maxdepth 1 -type d -name 'wtfbsd-installer.*' | wc -l | tr -d ' ')
check "the state directory is gone after the second run" "0" "${left}"

finish

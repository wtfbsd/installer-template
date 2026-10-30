#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The log of a run lives in the state directory of the run, which is private
# and is gone when the run ends.  The copy that is kept is made without
# following a link that is in the way.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-log.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT

# The log of the run is written in the state directory and never in a path
# that everybody shares.
unset INSTALLER_LOG
tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"

kept="${tmp}/wtfbsd-installer.log"
if [ -f "${kept}" ]; then
	printf 'ok   the log of the run is kept\n'
else
	printf 'FAIL the log of the run is not kept: %s\n' "${kept}"
	fails=$((fails + 1))
fi
check_contains "the log holds the output of the backend" \
	"install: writing the system files" "$(cat "${kept}" 2>/dev/null || true)"

# The log of the run never lands in a path that somebody else can name
# before the run starts: a link that is planted there is not written
# through.
victim="${tmp}/the-file-that-must-not-change.txt"
printf 'the content that has to stay\n' > "${victim}"
rm -f "${kept}"
ln -s "${victim}" "${kept}"

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes with a link in the way" 0 "${tui_rc}"

check "the file the link points at is not written" \
	"the content that has to stay" "$(cat "${victim}")"
check_absent "the link is not written through" \
	"install: writing the system files" "$(cat "${victim}")"

finish

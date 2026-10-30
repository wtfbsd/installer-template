#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The status of the installation is written down: the file that holds it
# holds the exit code of the backend even when the installation fails, and a
# disk that cannot be used is not a failed installation, because nothing was
# installed.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-status.XXXXXX")
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

# The rehearsal whose installation ends with the code 3.
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture-fail.conf"
export INSTALLER_ADAPTER_FIXTURE

tui_run "${root}/tests/fixtures/answers-fail.txt"

# The file that holds the status of the installation holds the code the
# backend returned and not the code of the front end.
code=$(awk -F'\t' '$1 == "RC" { print $2; exit }' "${BSDDIALOG_LOG}")
check "the exit code of the backend is written down" "3" "${code}"

# The status is caught by the function itself and not by the shell: the
# function is called where the shell stops at the first failure, and the
# file of the status is written down even then.
capture=$(sed -n '/^run_install()/,/^}/p' "${root}/bin/installer-tui" |
	grep -c '|| code=\$?' || true)
check "the exit code of the backend is caught in the function" "1" "${capture}"

# A disk that cannot be used: the check of the disk fails before anything
# is installed, so the run is not a failed installation.
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
export INSTALLER_ADAPTER_FIXTURE

tui_run "${root}/tests/fixtures/answers-disk-invalid.txt"

check_rc "the run ends well when nothing was installed" 0 "${tui_rc}"
check_absent "the run does not say that the installation did not finish" \
	"did not finish" "${tui_out}"
check_contains "the screen of the disk that cannot be used is shown" \
	"The chosen disk cannot be used" "$(cat "${BSDDIALOG_LOG}")"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text front end has the step "Additional software" too: a menu with
# a check list of the items, Select all (not the items for non-commercial
# use or that need a vendor key), a pager for every licence and the
# open-source licences.  Nothing is chosen for the user; the choice goes to
# the answers as ACCEPT_LICENSES.  Without a catalogue there is no step.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-tui-software.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture-software.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-software.txt"
check_rc "the installer installs with the licences chosen" 0 "${tui_rc}"
log=$(cat "${BSDDIALOG_LOG}")
check_contains "the step is there" "ExampleBSD Installer [Additional software]" "${log}"
check_contains "nothing is chosen at first" "Chosen: nothing" "${log}"
check_contains "Select all chose the items it may" \
	"Chosen: example-gpu-driver example-wifi-firmware example-browser-drm" "${log}"
check_contains "the licence is shown in a pager" "example-gpu-eula.txt" "${log}"
check_contains "the check list shows the flags" "Example Display font family [non-commercial]" "${log}"
check "the answers hold exactly what was ticked" \
	"ACCEPT_LICENSES=example-gpu-driver,example-display-font" \
	"$(grep '^ACCEPT_LICENSES=' "${INSTALLER_ANSWERS}" || true)"
check_contains "the summary names the accepted items" \
	"Additional software (licences accepted): example-gpu-driver, example-display-font" "${log}"

# Without a catalogue there is no step: the answers of the happy path work
# unchanged.
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
export INSTALLER_ADAPTER_FIXTURE
tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "without a catalogue the installer installs" 0 "${tui_rc}"
check_absent "without a catalogue there is no step" "[Additional software]" \
	"$(cat "${BSDDIALOG_LOG}")"
check_absent "and nothing is accepted" "ACCEPT_LICENSES" "$(cat "${INSTALLER_ANSWERS}")"

# The prompts of a system without a dialog tool have the pager as well.
out=$(printf '\n' | "${root}/bin/installer-prompt" --title T --textbox \
	"${root}/tests/fixtures/software/licences/example-drm.txt" 0 0)
check_contains "the prompts show a licence" "EXAMPLE CONTENT DECRYPTION MODULE TERMS" "${out}"

finish

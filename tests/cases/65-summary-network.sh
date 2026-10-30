#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The summary shows what the installation will use: a manual address is
# shown with the address, the netmask and the gateway the user gave.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-summary.XXXXXX")
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

tui_run "${root}/tests/fixtures/answers-static.txt"
check_rc "the installer finishes with a manual address" 0 "${tui_rc}"

summary=$(cat "${BSDDIALOG_LOG}")
check_contains "the summary shows the address" "static-address" "${summary}"
check_contains "the summary shows the netmask" "static-netmask" "${summary}"
check_contains "the summary shows the gateway" "static-gateway" "${summary}"

answers=$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)
check_contains "the answers hold the address" "IPV4_ADDR=static-address" \
	"${answers}"
check_contains "the answers hold the netmask" "IPV4_MASK=static-netmask" \
	"${answers}"
check_contains "the answers hold the gateway" "IPV4_GW=static-gateway" \
	"${answers}"

# An automatic address has no address, no netmask and no gateway.
tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"

summary=$(cat "${BSDDIALOG_LOG}")
check_absent "the summary shows no address" "static-address" "${summary}"
check_absent "the summary shows no netmask" "static-netmask" "${summary}"
check_absent "the summary shows no gateway" "static-gateway" "${summary}"

answers=$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)
check_absent "the answers hold no netmask" "IPV4_MASK=" "${answers}"

finish

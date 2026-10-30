#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The configured default is the one the installer offers first: the menu
# starts on it and the backend accepts it even when it is not in the short
# list of layouts or of time zones.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-default.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
export INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
export INSTALLER_CONF="${root}/tests/fixtures/installer-uk.conf"

answers="${tmp}/answers.conf"
printf 'KEYMAP=uk.kbd\n' > "${answers}"
rc=0
INSTALLER_ANSWERS="${answers}" "${backend}" keyboard validate >/dev/null 2>&1 || rc=$?
check_rc "the configured keyboard layout is accepted" 0 "${rc}"

printf 'TIMEZONE=Europe/London\n' > "${answers}"
rc=0
INSTALLER_ANSWERS="${answers}" "${backend}" timezone validate >/dev/null 2>&1 || rc=$?
check_rc "the configured time zone is accepted" 0 "${rc}"

printf 'KEYMAP=uk\n' > "${answers}"
rc=0
INSTALLER_ANSWERS="${answers}" "${backend}" keyboard validate >/dev/null 2>&1 || rc=$?
check_rc "a layout that is not known is refused" 2 "${rc}"

# The menus start on the configured default.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes with the configured defaults" 0 "${tui_rc}"

TAB=$(printf '\t')
dialog_log=$(cat "${BSDDIALOG_LOG}")
check_contains "the keyboard menu starts on the configured layout" \
	"--default-item${TAB}uk.kbd" "${dialog_log}"
check_contains "the time zone menu starts on the configured zone" \
	"--default-item${TAB}Europe/London" "${dialog_log}"

finish

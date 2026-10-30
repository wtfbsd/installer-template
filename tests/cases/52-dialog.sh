#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The way the front end talks to the dialog tool: the choice of the user is
# read from the output descriptor of the tool and never from its screen, the
# second button of every dialog is Back and the privileged access of the
# first account asks for a password unless the user says otherwise.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-dialog.XXXXXX")
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

log="${BSDDIALOG_LOG}"
calls=$(grep -c '^CALL' "${log}") || calls=0
check "the front end used the dialog tool" "1" "$([ "${calls}" -gt 0 ] && printf 1 || printf 0)"

named=$(grep -c -- '--output-fd' "${log}") || named=0
# A yes or no box writes nothing: the answer of the user is the exit code of
# the dialog alone, so such a box is given no output descriptor.  Every other
# dialog names the descriptor it writes the choice of the user to.
page_calls=$(grep '^CALL' "${log}" | grep -vc -- '--yesno') || page_calls=0
check "every dialog that is not a yes or no box names the output descriptor" \
	"${page_calls}" "${named}"

yesno_calls=$(grep '^CALL' "${log}" | grep -c -- '--yesno') || yesno_calls=0
check "there are yes or no boxes" "1" \
	"$([ "${yesno_calls}" -gt 0 ] && printf 1 || printf 0)"

stdout_calls=$(grep -c -- '--stdout' "${log}") || stdout_calls=0
check "no dialog asks for the screen on standard output" "0" "${stdout_calls}"

# The gauge widget has no buttons, so it has no cancel label.  A yes or no
# box names its buttons Yes and No, so it has no cancel label either.
page_dialogs=$(grep '^CALL' "${log}" | grep -v -- '--gauge' |
	grep -vc -- '--yesno') || page_dialogs=0
labels=$(awk -F'\t' '
	/^LABEL/ && $2 == "--cancel-label" { count++ }
	END { print count + 0 }
' "${log}")
check "every dialog of a page has a cancel label" "${page_dialogs}" "${labels}"

wrong=$(awk -F'\t' '
	/^LABEL/ && $2 == "--cancel-label" && $3 != "Back" { count++ }
	END { print count + 0 }
' "${log}")
check "the cancel label of every dialog is Back" "0" "${wrong}"

# The privileged access of the first account asks for a password when the
# user says nothing.
answer_text=$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)
check_contains "the default asks for a password" \
	"PRIVILEGE_PASSWORDLESS=no" "${answer_text}"

# Without --output-fd the stand-in writes the answer to standard error, the
# way the real tool does.
printf '0 the-answer\n' > "${tmp}/one.txt"
: > "${tmp}/state.txt"
out=$(BSDDIALOG_SCRIPT="${tmp}/one.txt" BSDDIALOG_STATE="${tmp}/state.txt" \
	"${BSDDIALOG}" --inputbox 'A question' 0 0 2>"${tmp}/err.txt" || true)
check_absent "the answer is not on standard output" "the-answer" "${out}"
check_contains "the answer is on standard error" \
	"the-answer" "$(cat "${tmp}/err.txt")"

# A yes or no box writes nothing: the answer of the user is the exit code
# of the dialog and nothing else.
printf '0\n' > "${tmp}/yes.txt"
: > "${tmp}/yes-state.txt"
out=$(BSDDIALOG_SCRIPT="${tmp}/yes.txt" BSDDIALOG_STATE="${tmp}/yes-state.txt" \
	"${BSDDIALOG}" --yesno 'A question' 0 0 2>"${tmp}/yes-err.txt" || true)
check "a yes or no box writes nothing" "" "$(cat "${tmp}/yes-err.txt")"
answers=$(printf '%s\n' "${out}" | sed -n 's/^\(yes\|no\)$/\1/p')
check "a yes or no box writes no answer" "" "${answers}"

finish

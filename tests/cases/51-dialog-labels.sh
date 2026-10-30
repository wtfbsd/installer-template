#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The labels of the buttons: the caller of the dialog tool says what the
# buttons of a dialog are called.  A dialog of a page has an OK button and a
# Back button, a yes or no box has a Yes button and a No button and the
# welcome page offers to quit.  The buttons that leave the installer are
# called Quit: the case that checks them is 64-dialog-quit.sh.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-labels.XXXXXX")
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

# labels_of — the labels of every call, one per line: the kind of the
# dialog, the title of the dialog, the label and the text of the label.
labels_of() {
	awk -F'\t' '
		/^CALL/ {
			widget = ""
			title = ""
			for (i = 1; i <= NF; i++) {
				if ($i == "--title" && i < NF) title = $(i + 1)
				if ($i ~ /^--(menu|radiolist|checklist|inputbox|passwordbox|msgbox|yesno|gauge)$/) {
					widget = $i
				}
			}
			next
		}
		/^LABEL/ { print widget "\t" title "\t" $2 "\t" $3 }
	' "${log}"
}

# The number of the calls of a kind.
calls_of() { # calls_of <widget>
	awk -F'\t' -v want="$1" '
		/^CALL/ {
			for (i = 1; i <= NF; i++) if ($i == want) { count++; break }
		}
		END { print count + 0 }
	' "${log}"
}

# A dialog of a page has an OK button and a Back button.
wrong=$(labels_of | awk -F'\t' '
	$1 == "--yesno" || $1 == "--gauge" || $1 == "" { next }
	$3 == "--ok-label" && $4 != "OK" { count++ }
	$3 == "--cancel-label" && $4 != "Back" { count++ }
	END { print count + 0 }
')
check "every dialog of a page has an OK button and a Back button" "0" "${wrong}"

page_dialogs=$(calls_of '--menu')
page_dialogs=$((page_dialogs + $(calls_of '--inputbox')))
page_dialogs=$((page_dialogs + $(calls_of '--radiolist')))
page_dialogs=$((page_dialogs + $(calls_of '--checklist')))
page_dialogs=$((page_dialogs + $(calls_of '--passwordbox')))
page_dialogs=$((page_dialogs + $(calls_of '--msgbox')))
ok_labels=$(labels_of | awk -F'\t' '$3 == "--ok-label"' | wc -l | tr -d ' ')
check "every dialog of a page names its OK button" "${page_dialogs}" "${ok_labels}"

back_labels=$(labels_of | awk -F'\t' '$3 == "--cancel-label"' | wc -l | tr -d ' ')
check "every dialog of a page names its Back button" "${page_dialogs}" "${back_labels}"

# A yes or no box has a Yes button and a No button.
yesno_calls=$(calls_of '--yesno')
yes_labels=$(labels_of | awk -F'\t' '$1 == "--yesno" && $3 == "--yes-label"' |
	wc -l | tr -d ' ')
check "every yes or no box names its Yes button" "${yesno_calls}" "${yes_labels}"

no_labels=$(labels_of | awk -F'\t' '$1 == "--yesno" && $3 == "--no-label"' |
	wc -l | tr -d ' ')
check "every yes or no box names its No button" "${yesno_calls}" "${no_labels}"

wrong=$(labels_of | awk -F'\t' '
	$1 != "--yesno" { next }
	$3 == "--yes-label" && $4 != "Yes" { count++ }
	END { print count + 0 }
')
check "the Yes button of a yes or no box is Yes" "0" "${wrong}"

# The welcome page offers to quit: its second button is Quit and not No.
wrong=$(labels_of | awk -F'\t' '
	$1 != "--yesno" { next }
	$2 ~ /\[Welcome\]$/ {
		welcome = 1
		if ($3 == "--no-label" && $4 != "Quit") count++
		next
	}
	$3 == "--no-label" && $4 != "No" { count++ }
	END { print count + 0 }
')
check "the second button of the welcome page is Quit" "0" "${wrong}"

welcome=$(labels_of | awk -F'\t' '$1 == "--yesno" && $2 ~ /\[Welcome\]$/' |
	wc -l | tr -d ' ')
if [ "${welcome}" -gt 0 ]; then
	printf 'ok   the welcome page is a yes or no box\n'
else
	printf 'FAIL the welcome page is not a yes or no box\n'
	fails=$((fails + 1))
fi

# The gauge has no buttons at all.
gauge_labels=$(labels_of | awk -F'\t' '$1 == "--gauge"' | wc -l | tr -d ' ')
check "the gauge has no labels" "0" "${gauge_labels}"

finish

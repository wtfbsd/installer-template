#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The buttons that leave the installer are called Quit, and a yes or no box
# is given no output descriptor: the answer of the user is the exit code of
# the dialog alone, and there is nothing to read.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-quit.XXXXXX")
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

# labels_of — the labels of every call, one per line: the kind of the
# dialog, the title of the dialog, whether the dialog asks to quit, the kind
# of the label and the label itself.
labels_of() {
	awk -F'\t' '
		/^CALL/ {
			widget = ""
			title = ""
			quit = 0
			for (i = 1; i <= NF; i++) {
				if ($i == "--title" && i < NF) title = $(i + 1)
				if ($i ~ /^--(menu|radiolist|checklist|inputbox|passwordbox|msgbox|yesno|gauge)$/) {
					widget = $i
				}
				if ($i == "Quit the installer?") quit = 1
			}
			next
		}
		/^LABEL/ { print widget "\t" title "\t" quit "\t" $2 "\t" $3 }
	' "${BSDDIALOG_LOG}"
}

# yesno_with_fd — the number of yes or no boxes that were given an output
# descriptor.
yesno_with_fd() {
	awk -F'\t' '
		/^CALL/ {
			yesno = 0
			fd = 0
			for (i = 1; i <= NF; i++) {
				if ($i == "--yesno") yesno = 1
				if ($i == "--output-fd") fd = 1
			}
			if (yesno && fd) count++
		}
		END { print count + 0 }
	' "${BSDDIALOG_LOG}"
}

# A machine without a disk: the screen before the first page opens.
printf 'DISKS=\nINTERFACES=em0\n' > "${tmp}/empty-fixture.conf"
INSTALLER_ADAPTER_FIXTURE="${tmp}/empty-fixture.conf"
export INSTALLER_ADAPTER_FIXTURE

tui_run "${root}/tests/fixtures/answers-nodisk.txt"
check_rc "the installer leaves without installing when there is no disk" \
	0 "${tui_rc}"

# The button that leaves the installer is called Quit and not Back.
wrong=$(labels_of | awk -F'\t' '
	$2 ~ /\[Unfortunately\]$/ && $4 == "--cancel-label" && $5 != "Quit" { count++ }
	END { print count + 0 }
')
check "the button that leaves the installer is called Quit" "0" "${wrong}"

back=$(labels_of | awk -F'\t' '
	$2 ~ /\[Unfortunately\]$/ && $4 == "--cancel-label" && $5 == "Back" { count++ }
	END { print count + 0 }
')
check "the screen before the first page has no Back button" "0" "${back}"

# The item that leaves the installer is called Quit as well.
stay=$(awk -F'\t' '
	{ for (i = 1; i <= NF; i++) if ($i == "Stay") count++ }
	END { print count + 0 }
' "${BSDDIALOG_LOG}")
check "no item is called Stay" "0" "${stay}"

quit_item=$(printf 'Quit\tStay in the live system and do not install anything')
check_contains "the screen offers to leave the installer" "${quit_item}" \
	"$(cat "${BSDDIALOG_LOG}")"

# No yes or no box is given an output descriptor.
check "no yes or no box names an output descriptor" "0" "$(yesno_with_fd)"

# The escape key asks whether to leave the installer, and the button that
# leaves is called Quit.
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
export INSTALLER_ADAPTER_FIXTURE

tui_run "${root}/tests/fixtures/answers-escape.txt"
check_rc "the run goes on when the question to quit is answered with no" \
	0 "${tui_rc}"

wrong=$(labels_of | awk -F'\t' '
	$3 == 1 && $4 == "--yes-label" && $5 != "Quit" { count++ }
	END { print count + 0 }
')
check "the button that quits is called Quit" "0" "${wrong}"

wrong=$(labels_of | awk -F'\t' '
	$3 == 1 && $4 == "--no-label" && $5 != "Continue" { count++ }
	END { print count + 0 }
')
check "the button that stays is called Continue" "0" "${wrong}"

check "no yes or no box names an output descriptor" "0" "$(yesno_with_fd)"

# The happy path: the welcome page and the summary are yes or no boxes too.
tui_run "${root}/tests/fixtures/answers-happy.txt"
check_rc "the installer finishes on the happy path" 0 "${tui_rc}"
check "no yes or no box names an output descriptor" "0" "$(yesno_with_fd)"

finish

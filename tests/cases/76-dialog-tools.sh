#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text front end works with every dialog tool the systems ship:
# bsddialog(1) (FreeBSD base), dialog(1) (the package of OpenBSD and
# NetBSD, whose escape key exits with 255), and without either with plain
# prompts on the terminal (bin/installer-prompt).

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-dialogs.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

fixtures="${root}/tests/fixtures"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A PATH without bsddialog and dialog: the tools of the system, linked one
# by one, and nothing else.
bare="${tmp}/bin"
mkdir -p "${bare}"
for tool in sh cat sed awk grep tr cut tee mktemp rm mv cp chmod mkdir dirname \
	basename ls head tail sort wc printf env id stat python3 date sleep find \
	uname expr stty test; do
	found=$(command -v "${tool}" 2>/dev/null || true)
	case "${found}" in
		/*) ln -s "${found}" "${bare}/${tool}" ;;
	esac
done

# ------------------------------------------------------------- dialog(1)
BSDDIALOG="${fixtures}/fake-dialog"
export BSDDIALOG
tui_run "${fixtures}/answers-happy.txt"
check_rc "dialog: the installer installs" 0 "${tui_rc}"
check_contains "dialog: the run reaches the finished page" "is installed" "$(cat "${BSDDIALOG_LOG}")"
# The escape key of dialog exits with 255: the installer asks whether to
# quit, the way it does for the 5 of bsddialog.
tui_run "${fixtures}/answers-escape.txt"
check_rc "dialog: the escape key (255) asks and the run goes on" 0 "${tui_rc}"
check_contains "dialog: the escape key asks whether to quit" "Quit the installer?" \
	"$(cat "${BSDDIALOG_LOG}")"

# dialog(1) exits with 255 for every error as well: a tool that always
# fails must not bring the same dialog back for ever.  timeout(1) ends a
# run that loops; the run has to end long before it, with exit code 3, a
# message and a small log.
failing="${tmp}/failing/dialog"
mkdir -p "${tmp}/failing"
printf '#!/bin/sh\necho x >> "%s/failing.calls"\necho "Error: the terminal is not usable" >&2\nexit 255\n' \
	"${tmp}" > "${failing}"
# The same tool whose "Quit the installer?" box says Continue (1): the
# escape key that never ends.
escaping="${tmp}/escaping/dialog"
mkdir -p "${tmp}/escaping"
cat > "${escaping}" <<STUB
#!/bin/sh
echo x >> "${tmp}/escaping.calls"
for arg in "\$@"; do
	[ "\${arg}" = 'Quit the installer?' ] && exit 1
done
exit 255
STUB
chmod +x "${failing}" "${escaping}"
if command -v timeout >/dev/null 2>&1; then
	for kind in failing escaping; do
		# A failing tool stops at its first "Quit the installer?" box (the
		# screen and that box: two calls); the escape key that never ends
		# stops at the third escape of the screen (five calls).
		case "${kind}" in
			failing) why='failed (exit code 255) on the box "Quit the installer?"'; most=2 ;;
			*) why='three times in a row on the same screen'; most=5 ;;
		esac
		rm -f "${tmp}/${kind}.calls" "${INSTALLER_LOG}"
		started=$(date +%s)
		rc=0
		out=$(BSDDIALOG="${tmp}/${kind}/dialog" timeout 10 "${root}/bin/installer-tui" \
			2>&1 < /dev/null) || rc=$?
		took=$(( $(date +%s) - started ))
		check_rc "dialog that is ${kind}: the installer stops with exit code 3" 3 "${rc}"
		check "dialog that is ${kind}: it stops at once" yes \
			"$([ "${took}" -lt 5 ] && echo yes || echo no)"
		check_contains "dialog that is ${kind}: the message names the dialog tool" \
			"installer-tui: the dialog tool" "${out}"
		check_contains "dialog that is ${kind}: the message says why" "${why}" "${out}"
		calls=$(wc -l < "${tmp}/${kind}.calls" 2>/dev/null || echo 0)
		check "dialog that is ${kind}: the tool ran ${most} times at most" yes \
			"$([ "${calls}" -le "${most}" ] && echo yes || echo no)"
		size=$(cat "${INSTALLER_LOG}" "${tmp}"/wtfbsd-installer.*/installer.log 2>/dev/null | wc -c)
		check "dialog that is ${kind}: the log stays small" yes \
			"$([ "${size}" -lt 8192 ] && echo yes || echo no)"
	done
else
	printf 'skip the failing dialog tool: no timeout(1)\n'
fi

# Found by itself: a system with dialog and without bsddialog.
unset BSDDIALOG
mkdir -p "${tmp}/withdialog"
printf '#!/bin/sh\nexec "%s/fake-dialog" "$@"\n' "${fixtures}" > "${tmp}/withdialog/dialog"
chmod +x "${tmp}/withdialog/dialog"
rm -f "${BSDDIALOG_LOG}" "${BSDDIALOG_STATE}"
rc=0
PATH="${tmp}/withdialog:${bare}" BSDDIALOG_SCRIPT="${fixtures}/answers-escape.txt" \
	"${root}/bin/installer-tui" > /dev/null 2>&1 || rc=$?
check_rc "without bsddialog the installer finds dialog by itself" 0 "${rc}"
check_contains "and treats its escape key as the escape key" "Quit the installer?" \
	"$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)"

# ------------------------------------------------------------- prompts
# Neither tool: the questions are plain prompts, answered on standard
# input.  Enter takes the default; < is the second button; ! is escape.
# welcome (Enter), keyboard (! then Continue with <, then Enter takes the
# default), time zone (Enter), disk (1), user name, an empty password and
# the message about it, the password twice, privileges (Enter), adapter,
# DHCP (Enter), summary (Enter), finished (Enter).
cat > "${tmp}/prompt-answers" <<'ANSWERS'

!
<


1
tester


s3cret-pass
s3cret-pass

em0



ANSWERS
rc=0
out=$(PATH="${bare}" LC_ALL=C "${root}/bin/installer-tui" < "${tmp}/prompt-answers" 2>&1) || rc=$?
check_rc "without a dialog tool the installer installs with prompts" 0 "${rc}"
check_contains "the prompts show the title of the page" "== ExampleBSD Installer [Disk] ==" "${out}"
check_contains "the prompts list the disks by number" "1)     ada0  Samsung SSD 860" "${out}"
check_contains "the escape key (!) asks whether to quit" "Quit the installer?" "${out}"
check_contains "an empty password is asked again" "A password is needed for tester" "${out}"
check_contains "the gauge is shown as lines" "[ 40%] writing the system files" "${out}"
check_contains "the run reaches the finished page" "ExampleBSD is installed." "${out}"
check_contains "the default of a menu is the configured layout" "[Enter: us | <: Back | !: Quit]" "${out}"
check_contains "the welcome question shows its keys" "Yes or Quit? [Enter: Yes | <: Quit | !: Quit]" "${out}"
check_contains "the user name prompt shows its keys" "[Enter: OK | <: Back | !: Quit] > " "${out}"
check_contains "the answers are written" "USER_NAME=tester" "$(cat "${INSTALLER_ANSWERS}")"
check_absent "the password is never shown" "s3cret-pass" "${out}"

# Every prompt shows its keys: what Enter does, the second button and the
# escape key, with a middle dot in a UTF-8 locale and a bar in any other.
# hint <locale> <answer> <arguments...> — the last line of the screen.
hint() {
	_loc=$1
	_in=$2
	shift 2
	printf '%s\n' "${_in}" | LC_ALL=${_loc} "${root}/bin/installer-prompt" --output-fd 3 "$@" \
		3>/dev/null 2>/dev/null | tail -n 1 || :
}
for loc in C.UTF-8 C; do
	case "${loc}" in
		*UTF-8) d='·' ;;
		*) d='|' ;;
	esac
	check "${loc}: a message shows its keys" "[Enter: OK ${d} !: Quit] " \
		"$(hint "${loc}" '' --msgbox 'Hello' 0 0)"
	check "${loc}: a yes or no question shows its keys" \
		"Install or Quit? [Enter: Install ${d} <: Quit ${d} !: Quit] " \
		"$(hint "${loc}" '' --yes-label Install --no-label Quit --yesno 'Go?' 0 0)"
	check "${loc}: an input box shows its keys" "[Enter: OK ${d} <: Back ${d} !: Quit] > " \
		"$(hint "${loc}" 'x' --ok-label OK --cancel-label Back --inputbox 'Name' 0 0)"
	check "${loc}: a password box shows its keys" "[Enter: OK ${d} <: Back ${d} !: Quit] > " \
		"$(hint "${loc}" 'x' --ok-label OK --cancel-label Back --passwordbox 'Password' 0 0)"
	check "${loc}: a menu shows its keys and its default" \
		"Number or tag [Enter: b ${d} <: Back ${d} !: Quit] > " \
		"$(hint "${loc}" '' --cancel-label Back --default-item b --menu 'Pick' 0 0 0 a first b second)"
	check "${loc}: a radio list shows its keys and the marked item" \
		"Number or tag [Enter: b ${d} <: Back ${d} !: Quit] > " \
		"$(hint "${loc}" '' --cancel-label Back --radiolist 'Pick' 0 0 0 a first off b second on)"
	check "${loc}: a check list shows its keys" \
		"Numbers or tags, separated by spaces [Enter: as marked ${d} <: Back ${d} !: Quit] > " \
		"$(hint "${loc}" '' --cancel-label Back --checklist 'Pick' 0 0 0 a first on b second off)"
done

# The prompts one by one: the codes of bsddialog.
prompt="${root}/bin/installer-prompt"
p() { # p <answer> <arguments...> — the choice in out, the code in rc
	_in=$1
	shift
	rc=0
	out=$(printf '%s\n' "${_in}" | "${prompt}" --output-fd 3 "$@" 3>&1 1>/dev/null) || rc=$?
}
p '2' --menu 'Pick' 0 0 0 a 'first' b 'second'
check "a menu takes a number" "b 0" "${out} ${rc}"
p 'a' --menu 'Pick' 0 0 0 a 'first' b 'second'
check "a menu takes a tag" "a 0" "${out} ${rc}"
p '' --default-item b --menu 'Pick' 0 0 0 a 'first' b 'second'
check "a menu takes the default on Enter" "b 0" "${out} ${rc}"
p '' --radiolist 'Pick' 0 0 0 a 'first' off b 'second' on
check "a radio list takes the marked item on Enter" "b 0" "${out} ${rc}"
p '1 b' --checklist 'Pick' 0 0 0 a 'first' off b 'second' off
check "a check list takes several" "a b 0" "${out} ${rc}"
p '<' --menu 'Pick' 0 0 0 a 'first'
check_rc "< is the second button" 1 "${rc}"
p '!' --inputbox 'Name' 0 0
check_rc "! is the escape key" 5 "${rc}"
p 'x' --passwordbox 'Secret' 0 0
check "a password box gives the line" "x 0" "${out} ${rc}"
p 'no' --yesno 'Sure?' 0 0
check_rc "a yes or no box: no" 1 "${rc}"
p '' --yesno 'Sure?' 0 0
check_rc "a yes or no box: Enter is yes" 0 "${rc}"
rc=0
"${prompt}" --nosuchbox x < /dev/null > /dev/null 2>&1 || rc=$?
check_rc "an unknown box is an error" 255 "${rc}"

finish

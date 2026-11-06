#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# An installation that is interrupted leaves nothing behind.
#
# The adapter makes a temporary file for the installation and a pipe for
# the output of the install command.  A run that is interrupted must
# remove them and must end with the code of the signal that interrupted
# it: a run that waits for the install command to end is a run that keeps
# writing to the target after the person asked it to stop, and a run that
# is killed leaves its temporary files in the temporary directory of the
# machine.
#
# The install command of this case sleeps, so that the run is interrupted
# while the installation is going on.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-interrupt.XXXXXX")
tmp_root=$(dirname "${tmp}")
run_pid=''
install_pid=''

# cleanup_case — the run and the install command are stopped, and
# everything the case made is gone.
cleanup_case() {
	[ -z "${run_pid}" ] || kill -KILL "${run_pid}" 2>/dev/null || :
	[ -z "${install_pid}" ] || kill -KILL "${install_pid}" 2>/dev/null || :
	[ ! -f "${tmp}/install-command.pid.child" ] ||
		kill -KILL "$(cat "${tmp}/install-command.pid.child")" 2>/dev/null || :
	rmrf "${tmp}" "${tmp_root}" || :
}
trap 'cleanup_case' EXIT INT TERM HUP

# The temporary directory of the run: the files of the run are made
# there and must be gone when the run ends.
mkdir -m 700 "${tmp}/runtmp"

mkdir -m 700 "${tmp}/secrets"
printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${tmp}/secrets/user.hash"

printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=freebsd\n' > "${tmp}/freebsd.conf"
printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' >> "${tmp}/freebsd.conf"
cat > "${tmp}/answers" <<ANSWERS
DISK=ada1
USER_NAME=wtfuser
USER_AUTH=password
USER_HASHFILE=${tmp}/secrets/user.hash
HOSTNAME=box1
NETWORK_MODE=dhcp
ANSWERS

# The install command of the case: it says that it runs, writes its
# process number down and waits, so that the run is interrupted while
# the installation is going on.
cat > "${tmp}/install-command.sh" <<'STUB'
#!/bin/sh
printf 'PROGRESS 5 writing the system files\n'
# The work runs in a child, as the real install commands run theirs: an
# interrupted run must stop it too.  The number of the child is written
# first: the case starts when the number of the command is there.
sleep 30 &
printf '%s\n' "$!" > "${INSTALLER_TEST_PIDFILE}.child"
printf '%s\n' "$$" > "${INSTALLER_TEST_PIDFILE}"
wait
printf 'PROGRESS 100 the system is installed\n'
STUB
chmod 755 "${tmp}/install-command.sh"

export INSTALLER_TEST_PIDFILE="${tmp}/install-command.pid"

# The adapter is run in the background: the case needs its process
# number to interrupt it.  The subshell writes the number of the adapter
# and the code it ended with, so that the case knows when the run ended.
(
	TMPDIR="${tmp}/runtmp" INSTALLER_CONF="${tmp}/freebsd.conf" \
		INSTALLER_ANSWERS="${tmp}/answers" \
		INSTALLER_INSTALL_COMMAND="${tmp}/install-command.sh" \
		"${root}/adapters/freebsd.sh" apply-install > "${tmp}/run.log" 2>&1 &
	_run=$!
	printf '%s\n' "${_run}" > "${tmp}/run.pid"
	_rc=0
	wait "${_run}" || _rc=$?
	printf '%s\n' "${_rc}" > "${tmp}/run.rc"
) &
runner=$!

# The install command has to run before the run is interrupted: the
# temporary files of the run exist from the moment the installation
# starts.
waited=0
while [ ! -f "${tmp}/install-command.pid" ]; do
	waited=$((waited + 1))
	[ "${waited}" -lt 200 ] || break
	sleep 0.1
done
if [ ! -f "${tmp}/install-command.pid" ]; then
	printf 'the install command did not run\n' >&2
	cat "${tmp}/run.log" >&2 || :
	exit 1
fi
install_pid=$(cat "${tmp}/install-command.pid")
run_pid=$(cat "${tmp}/run.pid")

# The files of the run exist while the installation goes on.
made=no
for _f in "${tmp}/runtmp"/wtfbsd-install-*; do
	[ -e "${_f}" ] || continue
	made=yes
	break
done
check "the run made a temporary file for the installation" yes "${made}"

kill -TERM "${run_pid}" 2>/dev/null || :

# The run must stop at once: the installation was interrupted, not
# waited for.
waited=0
while [ ! -f "${tmp}/run.rc" ]; do
	waited=$((waited + 1))
	[ "${waited}" -lt 100 ] || break
	sleep 0.1
done
check "the interrupted run stopped" yes \
	"$([ -f "${tmp}/run.rc" ] && echo yes || echo no)"

run_rc=$(cat "${tmp}/run.rc" 2>/dev/null || echo 0)
check_rc "the run interrupted by TERM ends with 143" 143 "${run_rc}"

left=''
for _f in "${tmp}/runtmp"/*; do
	[ -e "${_f}" ] || continue
	left="${left} ${_f##*/}"
done
check "no file of the run is left in the temporary directory" "" "${left}"

# alive <pid> — yes while the process runs; a zombie (killed, not yet
# reaped) does not run.
alive() {
	_st=$(ps -o stat= -p "$1" 2>/dev/null) || { printf 'no\n'; return; }
	case "${_st}" in ''|Z*) printf 'no\n' ;; *) printf 'yes\n' ;; esac
}
child_pid=$(cat "${INSTALLER_TEST_PIDFILE}.child" 2>/dev/null || :)
sleep 1
check "the install command was stopped" no "$(alive "${install_pid}")"
check "the work the install command started was stopped" no \
	"$(if [ -n "${child_pid}" ]; then alive "${child_pid}"; else echo yes; fi)"

finish

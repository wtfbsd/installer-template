#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The first account of the installed system: the name has to be a name the
# system can use, the name is asked again when it is not and an account
# needs a password unless the installer is told that it has none.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-users.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
export INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"

answers="${tmp}/answers.conf"
passfile="${tmp}/user.pass"
: > "${passfile}"
printf 'a password\n' > "${passfile}"

validate_user() { # validate_user <name> <auth> — the exit code of the check
	printf 'USER_NAME=%s\nUSER_AUTH=%s\n' "$1" "$2" > "${answers}"
	if [ "${2}" = password ]; then
		printf 'USER_PASSFILE=%s\n' "${passfile}" >> "${answers}"
	fi
	rc=0
	INSTALLER_ANSWERS="${answers}" "${backend}" users validate >/dev/null 2>&1 || rc=$?
	printf '%s\n' "${rc}"
}

check_rc "a name that may be used is accepted" 0 "$(validate_user tester password)"
check_rc "a name with a command in it is refused" 2 \
	"$(validate_user 'root;rm -rf /' password)"
check_rc "a name the system uses is refused" 2 "$(validate_user operator password)"
check_rc "the name of the system administrator is refused" 2 \
	"$(validate_user root password)"
check_rc "the name of the daemon of the high availability is refused" 2 \
	"$(validate_user hast password)"
check_rc "the name of the audit daemon is refused" 2 \
	"$(validate_user auditdistd password)"
check_rc "the name of the directory service is refused" 2 \
	"$(validate_user _ypldap password)"
check_rc "the name of the tests is refused" 2 "$(validate_user tests password)"

# An empty password is refused unless the account is told to have none.
: > "${passfile}"
check_rc "an empty password is refused" 2 "$(validate_user tester password)"
check_rc "an account without a password is accepted" 0 "$(validate_user tester none)"

# The account of the installed system may not be taken over.  The file of
# the accounts is the one of the system that is installed.
target="${tmp}/target"
mkdir -p "${target}/etc"
# The lines are built from fragments: the repository does not carry the
# shape of an address.
printf 'root:*:%s:%s:Unixes system administrator:/root:/bin/sh\n' 0 0 \
	> "${target}/etc/master.passwd"
printf 'targetuser:*:%s:%s:An account of the system:/var/empty:/bin/sh\n' \
	1001 1001 >> "${target}/etc/master.passwd"

fixture="${tmp}/target-fixture.conf"
printf 'DISKS=ada0|Samsung SSD 860|500107862016\nINTERFACES=em0\n' \
	> "${fixture}"
printf 'TARGET_ROOT=%s\n' "${target}" >> "${fixture}"

check_user() { # check_user <name> <fixture> <verb> — the exit code and the
	# message of the section of the accounts
	printf 'USER_NAME=%s\nUSER_AUTH=none\n' "$1" > "${answers}"
	rc=0
	out=$(INSTALLER_ANSWERS="${answers}" \
		INSTALLER_ADAPTER_FIXTURE="$2" \
		"${backend}" users "$3" 2>&1) || rc=$?
	printf '%s\n%s\n' "${rc}" "${out}"
}

# The account of the installed system may not be taken over: the check of
# the answers refuses it.
result=$(check_user targetuser "${fixture}" validate)
rc=$(printf '%s\n' "${result}" | sed -n '1p')
message=$(printf '%s\n' "${result}" | sed -n '2p')
check_rc "an account that is already in the installed system is refused" \
	2 "${rc}"
check_contains "the refusal names the account" "targetuser" "${message}"

result=$(check_user tester "${fixture}" validate)
rc=$(printf '%s\n' "${result}" | sed -n '1p')
check_rc "an account that is not in the installed system is accepted" 0 "${rc}"

# The section makes no account: the install step makes it.
result=$(check_user tester "${fixture}" apply)
rc=$(printf '%s\n' "${result}" | sed -n '1p')
message=$(printf '%s\n' "${result}" | sed -n '2p')
check_rc "the section of the accounts makes no account" 0 "${rc}"
check_contains "the section says that the install step makes the account" \
	"install step" "${message}"

# The system that is installed is not known before the installation: the
# check of the accounts is left out then.
printf 'DISKS=ada0|Samsung SSD 860|500107862016\nINTERFACES=em0\n' \
	> "${tmp}/no-target-fixture.conf"
result=$(check_user tester "${tmp}/no-target-fixture.conf" validate)
rc=$(printf '%s\n' "${result}" | sed -n '1p')
check_rc "the check of the accounts is left out when the system is not known" \
	0 "${rc}"

# The front end asks the name again and never picks one by itself.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

tui_run "${root}/tests/fixtures/answers-baduser.txt"
check_rc "the installer finishes after the name is asked again" 0 "${tui_rc}"
check_contains "the name that may be used is written" \
	"USER_NAME=tester" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check_absent "the refused name is not written" \
	"USER_NAME=root" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check_absent "the name of the daemon of the high availability is not written" \
	"USER_NAME=hast" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check_contains "the front end says that the name is refused" \
	"cannot be used" "$(cat "${BSDDIALOG_LOG}")"

tui_run "${root}/tests/fixtures/answers-emptypass.txt"
check_rc "the installer finishes after the password is asked again" 0 "${tui_rc}"
check_contains "the account has a password" \
	"USER_AUTH=password" "$(cat "${INSTALLER_ANSWERS}" 2>/dev/null || true)"
check_contains "the front end asks about the empty password" \
	"no password" "$(cat "${BSDDIALOG_LOG}")"

finish

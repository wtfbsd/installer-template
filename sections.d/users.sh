#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# users: the first account of the installed system.  The account needs a
# password unless the installer is told that privileged access is passwordless.
#
# The section checks the answers and it does not make the account: the
# install step makes the account and it reads the password file that the
# answer USER_PASSFILE names.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/accounts.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

OS=$(config_value OS) || exit 2

cmd_probe() {
	printf '{"section":"users","users":[],"privilege":"password"}\n'
}

cmd_validate() {
	name=$(answers_get USER_NAME) || die 2 'no user name was given'
	[ -n "${name}" ] || die 2 'the user name is empty'
	if user_name_reserved "${name}"; then
		die 2 "the user name '${name}' is a name the system uses"
	fi
	user_name_valid "${name}" || die 2 "the user name '${name}' cannot be used"
	auth=$(answers_get USER_AUTH) || auth=''
	case "${auth}" in
		password)
			passfile=$(answers_get USER_PASSFILE) ||
				die 2 'the account needs a password file'
			[ -f "${passfile}" ] || die 2 'the password file is not there'
			[ -s "${passfile}" ] || die 2 'the password of the account is empty'
			;;
		none) : ;;
		*) die 2 'the account authentication is not known' ;;
	esac
	case "$(answers_get PRIVILEGE_PASSWORDLESS || printf 'no')" in
		yes|no) : ;;
		*) die 2 'the privilege setting is not known' ;;
	esac
	# The account may not take the place of an account that the system
	# that is installed already has.  The file of the accounts is read
	# from the system that is installed, so the check needs to know where
	# that system is.  The check is left out when the root of that
	# system is not known: the system is not installed yet.
	target=$(adapter_cmd target-root) || target=''
	if [ -n "${target}" ] && [ -f "${target}/etc/master.passwd" ]; then
		if name_in_accounts "${target}/etc/master.passwd" "${name}"; then
			die 2 "the user name '${name}' is already an account of the system that is installed"
		fi
	fi
}

# cmd_apply — the section makes no account.  The install step makes it and
# it reads the password file that the answer USER_PASSFILE names.
cmd_apply() {
	printf 'users: the account is made by the install step\n'
}

cmd_verify() {
	:
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate) cmd_validate "$@" ;;
	apply) cmd_apply "$@" ;;
	verify) cmd_verify "$@" ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

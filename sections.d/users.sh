#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# users: the first account of the installed system.  The account needs a
# password unless the installer is told that privileged access is passwordless.
#
# The section checks the answers and it does not make the account: the
# install step makes the account from the crypt hash in the file that the
# answer USER_HASHFILE names.

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

# hash_scheme — the crypt scheme the system accepts, from the adapter.
# SHA-512 crypt when the adapter does not say.
hash_scheme() {
	_scheme=$(adapter_cmd hash-scheme 2>/dev/null) || _scheme=''
	case "${_scheme}" in
		sha512|bcrypt|bcrypt-2a) printf '%s\n' "${_scheme}" ;;
		*) printf 'sha512\n' ;;
	esac
}

cmd_probe() {
	printf '{"section":"users","users":[],"privilege":"password","hash_scheme":"%s"}\n' \
		"$(hash_scheme)"
}

# hostname_valid <name> — a host name of labels of letters, digits and
# dashes, separated by dots; a label neither starts nor ends with a dash.
hostname_valid() {
	[ "${#1}" -le 253 ] || return 1
	printf '%s\n' "$1" | grep -Eq -- \
		'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
}

# full_name_valid <text> — printable text without a colon (the separator
# of the account files), at most 64 characters.
full_name_valid() {
	[ "${#1}" -le 64 ] || return 1
	case "$1" in
		*:*) return 1 ;;
	esac
	_clean=$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')
	[ "${_clean}" = "$1" ]
}

# ssh_key_file_valid <file> — every line that is not empty and not a
# comment is a public key of a known type.
ssh_key_file_valid() {
	[ -f "$1" ] || return 1
	[ -s "$1" ] || return 1
	awk '
		/^[ \t]*(#|$)/ { next }
		$1 ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh[.]com)$/ && $2 ~ /^[A-Za-z0-9+\/]+=*$/ { keys++; next }
		{ bad = 1 }
		END { exit (bad || keys == 0) ? 1 : 0 }
	' "$1"
}

cmd_validate() {
	name=$(answers_get USER_NAME) || die 2 'no user name was given'
	[ -n "${name}" ] || die 2 'the user name is empty'
	if user_name_reserved "${name}"; then
		die 2 "the user name '${name}' is a name the system uses"
	fi
	user_name_valid "${name}" || die 2 "the user name '${name}' cannot be used"
	auth=$(answers_get USER_AUTH) || auth=''
	# The install command of the contract needs the hash of a password:
	# an account without a password cannot be installed.
	case "${auth}" in
		password) : ;;
		none) die 2 'the account needs a password' ;;
		*) die 2 'the account authentication is not known' ;;
	esac
	# Both front ends write the crypt hash of the password and never the
	# password itself.  The hash has to be in the scheme of the system.
	hashfile=$(answers_get USER_HASHFILE) ||
		die 2 'the account needs a password hash file'
	[ -f "${hashfile}" ] || die 2 'the password hash file is not there'
	[ -s "${hashfile}" ] || die 2 'the password hash file is empty'
	case "$(hash_scheme)" in
		bcrypt) prefix='$2b$' ;;
		bcrypt-2a) prefix='$2a$' ;;
		*) prefix='$6$' ;;
	esac
	# The whole file: one line, the whole crypt hash of the scheme (the
	# root helper checks the same, lib/hashes.py).
	python3 -I "${root}/lib/hashes.py" check "$(hash_scheme)" "${hashfile}" ||
		die 2 "the password hash file holds no crypt hash in the scheme of the system (${prefix})"
	if full=$(answers_get USER_FULLNAME) && [ -n "${full}" ]; then
		full_name_valid "${full}" ||
			die 2 'the full name may not hold a colon or a control character'
	fi
	if host=$(answers_get HOSTNAME) && [ -n "${host}" ]; then
		hostname_valid "${host}" || die 2 "the host name '${host}' cannot be used"
	fi
	if keyfile=$(answers_get SSH_KEYFILE) && [ -n "${keyfile}" ]; then
		ssh_key_file_valid "${keyfile}" ||
			die 2 'the SSH key is not a public key of a known type'
	fi
	case "$(answers_get ROOT_MODE || printf 'locked')" in
		locked) : ;;
		password)
			roothash=$(answers_get ROOT_HASHFILE) ||
				die 2 'root needs a password hash file'
			[ -s "${roothash}" ] || die 2 'the root password hash file is empty'
			python3 -I "${root}/lib/hashes.py" check "$(hash_scheme)" "${roothash}" ||
				die 2 'the root password hash file holds no crypt hash in the scheme of the system'
			;;
		*) die 2 'the root account is locked or has a password' ;;
	esac
	case "$(answers_get AUTOLOGIN || printf 'no')" in
		yes|no) : ;;
		*) die 2 'the automatic login is yes or no' ;;
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

# cmd_apply — the section makes no account.  The install step makes it from
# the hash file that the answer USER_HASHFILE names.
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

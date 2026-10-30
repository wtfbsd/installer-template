# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The rules of the first account of the installed system.  The front end and
# the backend both use them: the front end asks again when a name is not
# allowed and the backend refuses the answers that carry a name that is not
# allowed.

# reserved_user_names — the names the system uses for itself.  An account
# that carries one of them takes the place of a part of the system.
#
# The list holds the accounts that every system has and the accounts that
# the parts of the system use: the audit daemon, the directory service of
# the network and the daemon of the high availability.  The name of the
# tests is there as well: the tests of a system are run under a name of
# their own and an account of that name belongs to them.
reserved_user_names() {
	printf '%s\n' root toor daemon operator bin tty kmem games news man \
		sshd smmsp mailnull bind unbound proxy _pflogd _dhcp uucp pop www \
		ntpd nobody auditdistd _ypldap hast tests
}

# user_name_pattern — the shape of a name that the system accepts: a name
# starts with a letter or an underline and holds letters, digits, underlines
# and dashes.
user_name_pattern() {
	printf '%s\n' '^[a-z_][a-z0-9_-]{0,31}$'
}

# user_name_reserved <name> — succeed when the system uses the name.
user_name_reserved() {
	[ -n "${1:-}" ] || return 1
	reserved_user_names | grep -Fxq -- "$1"
}

# user_name_valid <name> — succeed when the name may be used for an account.
user_name_valid() {
	[ -n "${1:-}" ] || return 1
	printf '%s\n' "$1" | grep -Eq -- "$(user_name_pattern)" || return 1
	if user_name_reserved "$1"; then
		return 1
	fi
	return 0
}

# name_in_accounts <file> <name> — succeed when the account is in the file of
# the accounts of a system.
#
# The file of the accounts holds one line per account and the name of the
# account is the first field of the line.
name_in_accounts() {
	[ -f "$1" ] || return 1
	awk -F: -v name="$2" '
		$1 == name { found = 1 }
		END { exit found ? 0 : 1 }
	' "$1"
}

# write_secret_file <directory> <content> — write the password of the
# account to a file of its own in the directory.
#
# The file is made in a file of its own and moved into place afterwards, so
# that a reader never sees half a password and so that a file that is in
# the way is never written through.  The directory is made private and the
# file in it is private as well.
#
# A password file that is already there is never written over: the call
# fails and the file keeps the password it holds.
write_secret_file() {
	_dir=${1:-}
	_content=${2:-}
	[ -n "${_dir}" ] || return 1
	if [ -e "${_dir}/user.pass" ]; then
		return 1
	fi
	_write_secret_file "${_dir}" "${_content}"
}

# replace_secret_file <directory> <content> — write the password of the
# account over the password file that is there.  It is only used for the
# file that the run wrote itself.
replace_secret_file() {
	_write_secret_file "$1" "$2"
}

# _write_secret_file <directory> <content> — the writing of the password
# file itself.
_write_secret_file() {
	_dir=${1:-}
	_content=${2:-}
	[ -n "${_dir}" ] || return 1
	mkdir -p "${_dir}" || return 1
	chmod 700 "${_dir}" || return 1
	_tmp=$(umask 077 && mktemp "${_dir}/.user.pass.XXXXXX") || return 1
	if ! printf '%s\n' "${_content}" > "${_tmp}"; then
		rm -f "${_tmp}"
		return 1
	fi
	chmod 600 "${_tmp}" 2>/dev/null || :
	if ! mv -f "${_tmp}" "${_dir}/user.pass"; then
		rm -f "${_tmp}"
		return 1
	fi
	return 0
}

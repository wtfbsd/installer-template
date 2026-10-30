# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Shared helpers for the backend, the sections and the adapters.  Every script
# that uses this file sets "root" to the repository root first.

# die <exit code> <message...> — stop with a message on standard error.
die() {
	_code=$1
	shift
	printf 'installer-backend: %s\n' "$*" >&2
	exit "${_code}"
}

# json_escape <text> — escape a value for a JSON string.
json_escape() {
	_tab=$(printf '\t')
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/${_tab}/\\\\t/g"
}

# sanitize_text <text> — reduce a text to printable ASCII without a quote and
# without a backslash, so that it can be put in a JSON string without
# changing the meaning of the string around it.  The text of the hardware is
# read from the machine and is not trusted.
sanitize_text() {
	printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]"\\' | LC_ALL=C tr -cd ' -~'
}

# disk_name_valid <name> — succeed when the name is the name of a disk: a
# name of a disk starts with letters and ends with digits.
disk_name_valid() {
	[ -n "${1:-}" ] || return 1
	printf '%s\n' "$1" | grep -Eq -- '^[a-z]+[0-9]+$'
}

# kv_get <file> <key> — print the value of one KEY=value line; return 1 when
# the key is not in the file.
kv_get() {
	[ -f "$1" ] || return 1
	awk -F= -v key="$2" '
		$1 == key { found = 1; print substr($0, index($0, "=") + 1); exit }
		END { if (!found) exit 1 }
	' "$1"
}

# rmrf <path> <guardroot> — rm -rf only for a non-empty path under the root.
rmrf() {
	[ -n "${1:-}" ] || die 3 'rmrf: empty path'
	[ -n "${2:-}" ] || die 3 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die 3 "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die 3 "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

# adapter_cmd <operation> [arguments...] — run the adapter for this system.
# The adapter decides what the operation means; its exit code is the exit
# code of this call.
adapter_cmd() {
	_adapter="${root}/adapters/${OS}.sh"
	if [ ! -f "${_adapter}" ]; then
		die 3 "no adapter for the operating system '${OS}'"
	fi
	"${_adapter}" "$@"
}

# answers_get <key> — print one answer the front end collected.
answers_get() {
	[ -n "${INSTALLER_ANSWERS:-}" ] || return 1
	kv_get "${INSTALLER_ANSWERS}" "$1"
}

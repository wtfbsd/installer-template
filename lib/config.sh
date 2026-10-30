# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installer configuration: KEY=value text that is parsed, never sourced.
# A value is checked against an anchored pattern before it is used, so a
# value that tries to run a command is rejected instead of being run.

# config_file — the configuration file to read.
config_file() {
	printf '%s\n' "${INSTALLER_CONF:-${root}/installer.conf}"
}

# config_keys — the keys the installer needs.
config_keys() {
	printf '%s\n' PRODUCT_NAME PRODUCT_SLUG OS DEFAULT_KEYMAP DEFAULT_TZ
}

# config_known_key <key> — succeed when the key is one the installer knows.
config_known_key() {
	case "$1" in
		PRODUCT_NAME|PRODUCT_SLUG|OS|DEFAULT_KEYMAP|DEFAULT_TZ) return 0 ;;
		*) return 1 ;;
	esac
}

# config_valid_value <key> <value> — succeed when the value is well formed.
config_valid_value() {
	case "$1" in
		PRODUCT_NAME) _pattern='^[A-Za-z][A-Za-z0-9 ._-]{0,63}$' ;;
		PRODUCT_SLUG) _pattern='^[a-z][a-z0-9-]{0,63}$' ;;
		OS) _pattern='^(freebsd|netbsd|openbsd|dragonfly|illumos)$' ;;
		DEFAULT_KEYMAP) _pattern='^[A-Za-z0-9._-]{1,32}$' ;;
		DEFAULT_TZ) _pattern='^[A-Za-z][A-Za-z0-9+_-]*(/[A-Za-z0-9+_-]+)*$' ;;
		*) return 2 ;;
	esac
	printf '%s\n' "$2" | grep -Eq -- "${_pattern}"
}

# config_value <key> — print the validated value of one key.
config_value() {
	_file=$(config_file)
	if [ ! -f "${_file}" ]; then
		printf 'installer-config: no configuration file: %s\n' "${_file}" >&2
		return 2
	fi
	if ! _value=$(kv_get "${_file}" "$1"); then
		printf 'installer-config: no key %s in %s\n' "$1" "${_file}" >&2
		return 2
	fi
	if ! config_valid_value "$1" "${_value}"; then
		printf 'installer-config: invalid value for %s in %s\n' "$1" "${_file}" >&2
		return 2
	fi
	printf '%s\n' "${_value}"
}

# config_validate — read the whole file and check every line.
config_validate() {
	_file=$(config_file)
	if [ ! -f "${_file}" ]; then
		printf 'installer-config: no configuration file: %s\n' "${_file}" >&2
		return 2
	fi
	_rc=0
	_seen='|'
	_line=0
	while IFS= read -r _raw || [ -n "${_raw}" ]; do
		_line=$((_line + 1))
		_raw=${_raw%"$(printf '\r')"}
		case "${_raw}" in
			''|\#*) continue ;;
		esac
		case "${_raw}" in
			*=*) ;;
			*)
				printf 'installer-config: line %s is not KEY=value\n' "${_line}" >&2
				_rc=2
				continue
				;;
		esac
		_key=${_raw%%=*}
		_value=${_raw#*=}
		if ! printf '%s\n' "${_key}" | grep -Eq -- '^[A-Z][A-Z0-9_]*$'; then
			printf 'installer-config: line %s has an invalid key name\n' "${_line}" >&2
			_rc=2
			continue
		fi
		if ! config_known_key "${_key}"; then
			printf 'installer-config: line %s has the unknown key %s\n' \
				"${_line}" "${_key}" >&2
			_rc=2
			continue
		fi
		case "${_seen}" in
			*"|${_key}|"*)
				printf 'installer-config: line %s repeats the key %s\n' \
					"${_line}" "${_key}" >&2
				_rc=2
				continue
				;;
		esac
		_seen="${_seen}${_key}|"
		if ! config_valid_value "${_key}" "${_value}"; then
			printf 'installer-config: line %s has an invalid value for %s\n' \
				"${_line}" "${_key}" >&2
			_rc=2
		fi
	done < "${_file}"
	for _key in $(config_keys); do
		case "${_seen}" in
			*"|${_key}|"*) : ;;
			*)
				printf 'installer-config: the key %s is missing\n' "${_key}" >&2
				_rc=2
				;;
		esac
	done
	return "${_rc}"
}

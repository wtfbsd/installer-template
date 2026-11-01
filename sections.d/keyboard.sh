#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# keyboard: the keyboard layout the system is installed with.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

TAB=$(printf '\t')

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

# The layouts the section offers when the adapter has no list of its own
# (a rehearsal without KEYMAPS, or a system whose adapter is not written).
LAYOUTS='us gb de fr es'

OS=$(config_value OS) || exit 2

# layout_rows — "name<TAB>description" for every layout: the list of the
# adapter, or the list above.  The configured default comes first when it
# is not in the list.
layout_rows() {
	_rows=$(adapter_cmd keymaps 2>/dev/null) || _rows=''
	if [ -z "${_rows}" ]; then
		for _l in ${LAYOUTS}; do
			printf '%s\t%s\n' "${_l}" "$(layout_descr "${_l}")"
		done
		return 0
	fi
	printf '%s\n' "${_rows}"
}

layout_descr() {
	case "$1" in
		us) printf 'United States\n' ;;
		gb) printf 'United Kingdom\n' ;;
		de) printf 'Germany\n' ;;
		fr) printf 'France\n' ;;
		es) printf 'Spain\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

cmd_probe() {
	default=$(config_value DEFAULT_KEYMAP) || exit 2
	rows=$(layout_rows)
	printf '{"section":"keyboard","default":"%s","layouts":[' "${default}"
	first=1
	if ! printf '%s\n' "${rows}" | cut -f1 | grep -Fxq -- "${default}"; then
		printf '{"name":"%s","descr":"%s"}' "${default}" \
			"$(json_escape "$(layout_descr "${default}")")"
		first=0
	fi
	printf '%s\n' "${rows}" | while IFS="${TAB}" read -r name descr; do
		[ -n "${name}" ] || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"name":"%s","descr":"%s"}' \
			"$(json_escape "$(sanitize_text "${name}")")" \
			"$(json_escape "$(sanitize_text "${descr:-${name}}")")"
	done
	printf '],"locales":['
	first=1
	for l in $(locale_rows); do
		printf '%s\n' "${l}" | grep -Eq '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$' || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '"%s"' "${l}"
	done
	printf ']}\n'
}

# locale_rows — the locales of the system (UTF-8 only), one per line, from
# the adapter; nothing when it has no list.
locale_rows() {
	adapter_cmd locales 2>/dev/null || :
}

cmd_validate() {
	if locale=$(answers_get LOCALE) && [ -n "${locale}" ]; then
		printf '%s\n' "${locale}" | grep -Eq '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$' ||
			die 2 "the locale '${locale}' is not one of the form ll_CC.UTF-8"
		known=$(locale_rows)
		if [ -n "${known}" ] && ! printf '%s\n' "${known}" | grep -Fxq -- "${locale}"; then
			die 2 "the locale '${locale}' is not one this system has"
		fi
	fi
	layout=$(answers_get KEYMAP) || die 2 'no keyboard layout was chosen'
	default=$(config_value DEFAULT_KEYMAP) || exit 2
	[ "${layout}" = "${default}" ] && return 0
	layout_rows | cut -f1 | grep -Fxq -- "${layout}" ||
		die 2 "the keyboard layout '${layout}' is not known"
}

cmd_apply() {
	:
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

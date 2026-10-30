#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# keyboard: the keyboard layout the system is installed with.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

LAYOUTS='us gb de fr es'

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
	case " ${LAYOUTS} " in
		*" ${default} "*) : ;;
		*) LAYOUTS="${default} ${LAYOUTS}" ;;
	esac
	printf '{"section":"keyboard","default":"%s","layouts":[' "${default}"
	first=1
	for layout in ${LAYOUTS}; do
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"name":"%s","descr":"%s"}' \
			"${layout}" "$(json_escape "$(layout_descr "${layout}")")"
	done
	printf ']}\n'
}

cmd_validate() {
	layout=$(answers_get KEYMAP) || die 2 'no keyboard layout was chosen'
	default=$(config_value DEFAULT_KEYMAP) || exit 2
	case " ${LAYOUTS} " in
		*" ${layout} "*) : ;;
		*)
			if [ "${layout}" = "${default}" ]; then
				:
			else
				die 2 "the keyboard layout '${layout}' is not known"
			fi
			;;
	esac
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

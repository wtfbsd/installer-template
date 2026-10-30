#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# timezone: the time zone the system is installed with.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

ZONES='UTC America/New_York Europe/London Europe/Berlin Asia/Tokyo'

zone_descr() {
	case "$1" in
		UTC) printf 'Coordinated Universal Time\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

cmd_probe() {
	default=$(config_value DEFAULT_TZ) || exit 2
	case " ${ZONES} " in
		*" ${default} "*) : ;;
		*) ZONES="${default} ${ZONES}" ;;
	esac
	printf '{"section":"timezone","default":"%s","zones":[' "${default}"
	first=1
	for zone in ${ZONES}; do
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"name":"%s","descr":"%s"}' \
			"${zone}" "$(json_escape "$(zone_descr "${zone}")")"
	done
	printf ']}\n'
}

cmd_validate() {
	zone=$(answers_get TIMEZONE) || die 2 'no time zone was chosen'
	default=$(config_value DEFAULT_TZ) || exit 2
	case " ${ZONES} " in
		*" ${zone} "*) : ;;
		*)
			if [ "${zone}" = "${default}" ]; then
				:
			else
				die 2 "the time zone '${zone}' is not known"
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

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# timezone: the time zone the system is installed with.

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


OS=$(config_value OS) || exit 2

# zone_rows — "name<TAB>description" for every zone: the list of the
# adapter (the zone table of the system), or every zone of the installer's
# own table (lib/zone1970.tab), never a short list.  What the adapter says
# on standard error (a warning) goes to the log.
zone_rows() {
	_rows=$(adapter_cmd timezones) || _rows=''
	if [ -z "${_rows}" ]; then
		printf 'warning: no zone list from the adapter; the installer uses its own table\n' >&2
		printf 'UTC\tCoordinated Universal Time\n'
		awk -F '\t' '/^#/ || NF < 3 { next } { print $3 "\t" ((NF >= 4 && $4 != "") ? $4 : $3) }' \
			"${root}/lib/zone1970.tab" | sort -u
		return 0
	fi
	printf '%s\n' "${_rows}"
}

zone_descr() {
	case "$1" in
		UTC) printf 'Coordinated Universal Time\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

cmd_probe() {
	default=$(config_value DEFAULT_TZ) || exit 2
	rows=$(zone_rows)
	printf '{"section":"timezone","default":"%s","zones":[' "${default}"
	first=1
	if ! printf '%s\n' "${rows}" | cut -f1 | grep -Fxq -- "${default}"; then
		printf '{"name":"%s","descr":"%s"}' "${default}" \
			"$(json_escape "$(zone_descr "${default}")")"
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
	printf ']}\n'
}

cmd_validate() {
	case "$(answers_get CLOCK || printf 'utc')" in
		utc|local) : ;;
		*) die 2 'the hardware clock keeps utc or local time' ;;
	esac
	zone=$(answers_get TIMEZONE) || die 2 'no time zone was chosen'
	default=$(config_value DEFAULT_TZ) || exit 2
	[ "${zone}" = "${default}" ] && return 0
	zone_rows | cut -f1 | grep -Fxq -- "${zone}" ||
		die 2 "the time zone '${zone}' is not known"
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

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
		zone_list "${root}/lib/zone1970.tab" "${root}/lib/iso3166.tab"
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
	# The names and the texts of the zone tables are UTF-8 (Côte d'Ivoire):
	# kept as they are, without control characters, as JSON strings.
	printf '%s\n' "${rows}" | python3 -I -B -c '
import json, sys
first = sys.argv[1] == "1"
for raw in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n"):
    f = raw.split("\t")
    if not f[0]:
        continue
    f = ["".join(c for c in x if c.isprintable()) for x in f] + ["", ""]
    item = {"name": f[0], "descr": f[1] or f[0]}
    if f[2]:
        item["search"] = f[2]
    sys.stdout.write(("" if first else ",") + json.dumps(item, ensure_ascii=True, separators=(",", ":")))
    first = False
' "${first}"
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

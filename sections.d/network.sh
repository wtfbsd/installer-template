#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# network: how the installed system is connected.  The hardware itself is
# read by the adapter for the operating system.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

OS=$(config_value OS) || exit 2

cmd_probe() {
	interfaces=$(adapter_cmd network) || exit $?
	printf '{"section":"network","interfaces":%s}\n' "${interfaces}"
}

cmd_validate() {
	mode=$(answers_get NETWORK_MODE) || die 2 'no network mode was given'
	case "${mode}" in
		dhcp) : ;;
		offline) : ;;
		static)
			answers_get NET_IF >/dev/null ||
				die 2 'no network interface was chosen'
			answers_get IPV4_ADDR >/dev/null ||
				die 2 'no address was given'
			answers_get IPV4_MASK >/dev/null ||
				die 2 'no netmask was given'
			;;
		*) die 2 "the network mode '${mode}' is not known" ;;
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

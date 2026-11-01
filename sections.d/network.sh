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
. "${root}/lib/ipv4.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

OS=$(config_value OS) || exit 2

cmd_probe() {
	interfaces=$(adapter_cmd network) || exit $?
	online=$(adapter_cmd online-check 2>/dev/null) || online=no
	# The Wi-Fi adapters (by their drivers) and the networks each sees.
	scans=$(printf '%s' "${interfaces}" | python3 -I -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import netplan
for item in json.load(sys.stdin):
    if netplan.is_wifi(item.get("name", "")):
        print(item["name"])
' "${root}/lib" | while IFS= read -r ifname; do
		printf '%s\t' "${ifname}"
		adapter_cmd wifi-scan "${ifname}" 2>/dev/null | tr '\n' '\036'
		printf '\n'
	done)
	printf '%s' "${scans}" | INTERFACES="${interfaces}" ONLINE="${online}" python3 -I -c '
import json, os, sys
sys.path.insert(0, sys.argv[1])
import netplan
wifi = {}
for line in sys.stdin.read().split("\n"):
    if not line:
        continue
    name, _tab, rest = line.partition("\t")
    wifi[name] = netplan.parse_scan(rest.replace("\036", "\n"))
print(json.dumps({"section": "network", "interfaces": json.loads(os.environ["INTERFACES"]),
                  "wifi": wifi, "online": os.environ["ONLINE"].strip() == "yes"},
                 separators=(",", ":")))
' "${root}/lib"
}

cmd_validate() {
	# The adapters, the resolvers and the Wi-Fi network (lib/netplan.py).
	if problems=$(python3 -I "${root}/lib/netplan.py" check "${INSTALLER_ANSWERS:-/dev/null}" 2>&1); then
		:
	else
		die 2 "$(printf '%s' "${problems}" | tr '\n' ';')"
	fi
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
			arg_ipv4_ok "$(answers_get IPV4_ADDR)" ||
				die 2 'the address is not an IPv4 address'
			arg_ipv4_ok "$(answers_get IPV4_MASK)" ||
				die 2 'the netmask is not an IPv4 netmask'
			if gw=$(answers_get IPV4_GW) && [ -n "${gw}" ]; then
				arg_ipv4_ok "${gw}" || die 2 'the gateway is not an IPv4 address'
			fi
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

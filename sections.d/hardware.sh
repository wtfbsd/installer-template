#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# hardware: the parts of the machine (graphics, Wi-Fi, Ethernet, audio,
# input, Bluetooth), the driver each uses, whether its firmware is on the
# media, and whether it works.  Read only; the adapter reads it.

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
	report=$(adapter_cmd hardware 2>/dev/null) || report='{}'
	printf '%s' "${report}" | python3 -I -B -c '
import json, sys

def text(value, limit=80):
    value = "" if value is None else str(value)
    return "".join(c for c in value if c.isprintable())[:limit]

try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
devices = []
for d in (data.get("devices") or [] if isinstance(data, dict) else []):
    if not isinstance(d, dict):
        continue
    devices.append({k: text(d.get(k)) for k in ("class", "name", "driver", "firmware", "status")})
# What this system could not tell: shown as "not available", not an error.
unavailable = [text(u, 120) for u in (data.get("unavailable") or [] if isinstance(data, dict) else [])
               if isinstance(u, str)][:20]
print(json.dumps({"section": "hardware", "devices": devices, "unavailable": unavailable},
                 separators=(",", ":")))
'
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate|apply|verify) : ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

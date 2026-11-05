#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# disk: the disk the system is installed to.  The hardware itself is read by
# the adapter for the operating system.

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
	disks=$(adapter_cmd disks) || exit $?
	names=$(printf '%s' "${disks}" | python3 -I -B -c '
import json, sys
print(" ".join(d["name"] for d in json.load(sys.stdin) if isinstance(d, dict) and "name" in d))
') || names=''
	# shellcheck disable=SC2086
	detail=$(adapter_cmd disks-detail ${names} 2>/dev/null) || detail='{}'
	caps=$(adapter_cmd layouts 2>/dev/null) || caps='{}'
	image=$(adapter_cmd image-size 2>/dev/null) || image=''
	min_gb=$(config_value MIN_DISK_GB 2>/dev/null) || min_gb=''
	export IMAGE_BYTES="${image}" MIN_DISK_GB="${min_gb}"
	# The report is kept for the disks that may be written to only, its
	# text is reduced to plain values, and a disk the report does not know
	# gets what the list says.
	printf '%s' "${detail}" | DISKS_JSON="${disks}" CAPS_JSON="${caps}" python3 -I -B -c '
import json, os, sys

def text(value, limit=80):
    value = "" if value is None else str(value)
    value = "".join(c for c in value if c.isprintable() and c not in "\"\\")
    return value[:limit]

def number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0

disks = json.loads(os.environ["DISKS_JSON"])
try:
    detail = json.load(sys.stdin)
except ValueError:
    detail = {}
if not isinstance(detail, dict):
    detail = {}
known = {d.get("name"): d for d in detail.get("disks", []) if isinstance(d, dict)}
out = []
for disk in disks:
    name = disk["name"]
    rep = known.get(name, {})
    # An array the system assembled from members on other disks (RAIDframe
    # raid0, softraid sd8) is not a disk to install to: its members are
    # shown, as members of it.
    if rep.get("assembled"):
        continue
    health = rep.get("health") if isinstance(rep.get("health"), dict) else {}
    entry = {
        "name": name,
        "model": text(rep.get("model") or disk.get("descr")),
        "size_bytes": number(rep.get("size_bytes")) or disk.get("size_bytes", 0),
        "serial": text(rep.get("serial"), 40),
        "bus": text(rep.get("bus"), 16),
        "ssd": rep.get("ssd") if isinstance(rep.get("ssd"), bool) else None,
        "health": {k: (text(v) if isinstance(v, str) else number(v) if isinstance(v, int) else None)
                   for k, v in health.items() if k in ("status", "summary", "temperature_c",
                   "power_on_hours", "reallocated", "pending", "wear_percent")},
        "scheme": text(rep.get("scheme"), 16),
        "partitions": [{"kind": text(p.get("kind"), 16), "label": text(p.get("label"), 40),
                        "type": text(p.get("type"), 24), "fs": text(p.get("fs"), 16),
                        "size_bytes": number(p.get("size_bytes"))}
                       for p in rep.get("partitions", []) if isinstance(p, dict)],
        "os": [{"name": text(o.get("name"), 32), "detail": text(o.get("detail"), 64)}
               for o in rep.get("os", []) if isinstance(o, dict)],
        "free": [{"start_mb": number(f.get("start_mb")), "size_mb": number(f.get("size_mb"))}
                 for f in rep.get("free", []) if isinstance(f, dict)],
    }
    for key in ("member_of", "signature"):
        if rep.get(key):
            entry[key] = text(rep.get(key), 64)
    if number(rep.get("unknown_bytes")):
        entry["unknown_bytes"] = number(rep.get("unknown_bytes"))
    if not entry["health"]:
        entry["health"] = {"status": "unknown", "summary": "no health data"}
    out.append(entry)
boot = detail.get("boot_mode") if detail.get("boot_mode") in ("uefi", "bios") else ""
try:
    caps = json.loads(os.environ.get("CAPS_JSON") or "{}")
except ValueError:
    caps = {}
if not isinstance(caps, dict):
    caps = {}
# What the media needs (lib/diskplan.py min_disk_mb): the setting
# MIN_DISK_GB and the size of the installed image.
def digits(name):
    value = os.environ.get(name, "").strip()
    return int(value) if value.isdigit() and len(value) <= 15 else 0

requirements = {"min_disk_gb": digits("MIN_DISK_GB") or 16, "image_bytes": digits("IMAGE_BYTES")}
print(json.dumps({"section": "disk", "disks": disks,
                  "detail": {"boot_mode": boot, "ram_mb": number(detail.get("ram_mb")), "disks": out,
                             "capabilities": caps, "requirements": requirements}},
                 separators=(",", ":")))
'
}

cmd_validate() {
	disk=$(answers_get DISK) || die 2 'no disk was chosen'
	[ -n "${disk}" ] || die 2 'the chosen disk has no name'
	disk_name_valid "${disk}" || die 2 "the name '${disk}' is not the name of a disk"
	disks=$(adapter_cmd disks) || exit $?
	printf '%s' "${disks}" | DISK="${disk}" python3 -I -B -c '
import json, os, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("disk: the list of the disks is not JSON\n")
    sys.exit(1)

want = os.environ["DISK"]
for item in data:
    if isinstance(item, dict) and item.get("name") == want:
        sys.exit(0)
sys.exit(1)
' || die 2 "the chosen disk '${disk}' is not present"
	printf 'disk: the disk %s may be written to\n' "${disk}"
}

cmd_apply() {
	disk=$(answers_get DISK) || die 2 'no disk was chosen'
	adapter_cmd apply-disk "${disk}"
}

cmd_verify() {
	disk=$(answers_get DISK) || die 2 'no disk was chosen'
	adapter_cmd verify-disk "${disk}"
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate) cmd_validate "$@" ;;
	apply) cmd_apply "$@" ;;
	verify) cmd_verify "$@" ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

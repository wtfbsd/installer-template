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
	printf '{"section":"disk","disks":%s}\n' "${disks}"
}

cmd_validate() {
	disk=$(answers_get DISK) || die 2 'no disk was chosen'
	[ -n "${disk}" ] || die 2 'the chosen disk has no name'
	disk_name_valid "${disk}" || die 2 "the name '${disk}' is not the name of a disk"
	disks=$(adapter_cmd disks) || exit $?
	printf '%s' "${disks}" | DISK="${disk}" python3 -c '
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

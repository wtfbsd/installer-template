#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The size of a disk comes from diskinfo: the tool prints the size of the
# media in a line of its own and that line is the one that is read.  The
# size of geom is only used when diskinfo is not there.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-diskinfo.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

cat > "${tmp}/disk-info" <<'DISKS'
ada0	Samsung SSD 860	500107862016
DISKS

# The machine runs on a disk of its own.
printf '/dev/ada1p3 / ufs rw 0 0\n' > "${tmp}/mounts"

# probe_size — the size in bytes that the adapter reports for ada0.
probe_size() {
	PATH="${stubs}:${PATH}" \
	STUB_DISKS='ada0' \
	STUB_DISK_INFO="${tmp}/disk-info" \
	STUB_MOUNTS="${tmp}/mounts" \
	STUB_GEOM_SIZE="${geom_size:-}" \
	"${backend}" disk probe 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["disks"][0]["size_bytes"])
' || :
}

# The size of the media is the one of diskinfo.
check "the size comes from diskinfo" "500107862016" "$(probe_size)"

# geom says something else: the size of diskinfo wins.
geom_size=1234567
check "the size of diskinfo wins over the size of geom" "500107862016" \
	"$(probe_size)"
unset geom_size

# The stand-in for diskinfo prints the lines of the real tool.
out=$(PATH="${stubs}:${PATH}" STUB_DISK_INFO="${tmp}/disk-info" \
	diskinfo -v ada0 2>/dev/null || :)
check_contains "the stand-in prints the line of the media size" \
	"mediasize in bytes" "${out}"
check_contains "the stand-in prints the size of the media" \
	"500107862016" "${out}"

finish

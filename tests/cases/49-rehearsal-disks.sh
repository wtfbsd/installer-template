#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A rehearsal leaves out the disks that must not be written to as well: the
# disk of the running system and the disk of the installation media are not
# offered, exactly as they are not offered when the hardware is read from
# the machine.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-rehearsal.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

cat > "${tmp}/rehearsal.conf" <<'FIXTURE'
DISKS=ada0|Samsung SSD 860|500107862016,ada1|Samsung SSD 870|1000204886016,ada2|Crucial MX500|1000204886016
INTERFACES=em0|Intel I219-LM
FIXTURE

# The running system is on ada0 and the installation media is on ada1.
printf '/dev/ada0p3 / ufs rw 0 0\n/dev/ada1s1a /mnt ufs rw 0 0\n' \
	> "${tmp}/mounts"

offered() { # offered — the names of the disks that are offered
	PATH="${stubs}:${PATH}" \
	STUB_MOUNTS="${tmp}/mounts" \
	INSTALLER_ADAPTER_FIXTURE="${tmp}/rehearsal.conf" \
	"${backend}" disk probe 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(" ".join(item["name"] for item in data["disks"]))
' || :
}

check "the disk of the running system and the disk of the media are not offered" \
	"ada2" "$(offered)"

# A rehearsal without a machine to look at offers every disk of the file.
: > "${tmp}/empty-mounts"
printf 'DISKS=ada0|Samsung SSD 860|500107862016,ada1|Samsung SSD 870\n' \
	> "${tmp}/plain.conf"
out=$(PATH="${stubs}:${PATH}" \
	STUB_MOUNTS="${tmp}/empty-mounts" \
	INSTALLER_ADAPTER_FIXTURE="${tmp}/plain.conf" \
	"${backend}" disk probe 2>/dev/null) || out=''
check_contains "a rehearsal offers the disks of its file" '"name":"ada0"' "${out}"
check_contains "a rehearsal offers the disks of its file" '"name":"ada1"' "${out}"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text of the hardware is reduced to printable ASCII without a quote
# and without a backslash before it is put in the JSON: the adapters of the
# disks and of the network adapters use the same helper, so a description
# that carries a quote never breaks the JSON.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-json.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"

# A rehearsal whose hardware carries a quote and a backslash.  The file is
# written with a here document that is not expanded, so the text is the
# text.
cat > "${tmp}/odd.conf" <<'FIXTURE'
DISKS=ada0|Sa"msu\ng SSD|500107862016
INTERFACES=em0|In"tel \I219-LM,em1|Intel I210
FIXTURE

out=$(INSTALLER_ADAPTER_FIXTURE="${tmp}/odd.conf" \
	"${backend}" network probe 2>/dev/null) || out=''

check_contains "the network adapters are in the JSON" '"name":"em0"' "${out}"

printf '%s' "${out}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data["interfaces"]:
    descr = item["descr"]
    assert chr(34) not in descr, descr
    assert chr(92) not in descr, descr
    assert all(32 <= ord(c) <= 126 for c in descr), descr
' || fails=$((fails + 1))

out=$(INSTALLER_ADAPTER_FIXTURE="${tmp}/odd.conf" \
	"${backend}" disk probe 2>/dev/null) || out=''

printf '%s' "${out}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data["disks"]:
    descr = item["descr"]
    assert chr(34) not in descr, descr
    assert chr(92) not in descr, descr
    assert all(32 <= ord(c) <= 126 for c in descr), descr
' || fails=$((fails + 1))

finish

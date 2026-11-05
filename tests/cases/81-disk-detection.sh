#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The disk page shows what is on the disks now, read by lib/diskprobe.py from
# the tools of the system.  Here the outputs of the real tools, captured on
# FreeBSD 16 and NetBSD 11 (tests/fixtures/captures), are replayed through
# the root helper: Windows and Debian, Debian encrypted with LUKS, random
# data that is never called empty; on NetBSD the members of the RAIDframe
# array the kernel assembled are shown as members, and the array itself is
# neither listed nor accepted as the disk to install to.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-diskprobe.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

summary() { # summary — "disk: what is on it" lines of a --list disks report
	python3 -I -B -c '
import json, sys
data = json.load(sys.stdin)
for disk in data["detail"]["disks"]:
    found = "; ".join(o["detail"] for o in disk["os"]) or "empty"
    member = " [member of %s]" % disk["member_of"] if disk.get("member_of") else ""
    print("%s: %s%s" % (disk["name"], found, member))
print("offered: " + " ".join(d["name"] for d in data["disks"]))
'
}

out=$(INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-freebsd.conf" \
	bin/installer-apply --list disks 2>"${tmp}/err" | summary) && rc=0 || rc=$?
check_rc "the FreeBSD captures are read" 0 "${rc}"
check "what is on the FreeBSD disks" "vtbd2: Windows; Debian
vtbd4: Debian (encrypted with LUKS)
vtbd5: data the installer cannot read
offered: vtbd2 vtbd4 vtbd5" "${out}"

sed 's/^OS=.*/OS=netbsd/' installer.conf > "${tmp}/netbsd.conf"
out=$(INSTALLER_CONF="${tmp}/netbsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-netbsd.conf" \
	bin/installer-apply --list disks 2>"${tmp}/err" | summary) && rc=0 || rc=$?
check_rc "the NetBSD captures are read" 0 "${rc}"
check "the RAIDframe members, and no raid0" "ld4: OpenBSD
ld5: OpenBSD
ld6: a member of raid0 (RAIDframe RAID 1) [member of raid0 (RAIDframe RAID 1)]
ld7: a member of raid0 (RAIDframe RAID 1) [member of raid0 (RAIDframe RAID 1)]
offered: ld4 ld5 ld6 ld7" "${out}"

printf 'DISK=raid0\n' > "${tmp}/answers.conf"
INSTALLER_CONF="${tmp}/netbsd.conf" INSTALLER_ANSWERS="${tmp}/answers.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-netbsd.conf" \
	sections.d/disk.sh validate >/dev/null 2>&1 && rc=0 || rc=$?
check_rc "the assembled array is not a disk to install to" 2 "${rc}"
printf 'DISK=ld6\n' > "${tmp}/answers.conf"
INSTALLER_CONF="${tmp}/netbsd.conf" INSTALLER_ANSWERS="${tmp}/answers.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-netbsd.conf" \
	sections.d/disk.sh validate >/dev/null 2>&1 && rc=0 || rc=$?
check_rc "a member may be chosen (it is erased with a typed confirmation)" 0 "${rc}"

# OpenBSD assembled the softraid chunks as sd8: the chunks are members, sd8
# is neither listed nor accepted.  The arrays come from bioctl softraid0.
sed 's/^OS=.*/OS=openbsd/' installer.conf > "${tmp}/openbsd.conf"
out=$(INSTALLER_CONF="${tmp}/openbsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-openbsd.conf" \
	bin/installer-apply --list disks 2>"${tmp}/err" | summary) && rc=0 || rc=$?
check_rc "the OpenBSD captures are read" 0 "${rc}"
check "the softraid chunks are members, sd8 is not offered" "sd4: a member of sd8 (softraid RAID1); OpenBSD [member of sd8 (softraid RAID1)]
sd5: a member of sd8 (softraid RAID1); OpenBSD [member of sd8 (softraid RAID1)]
sd6: NetBSD RAIDframe member
sd7: NetBSD RAIDframe member
offered: sd4 sd5 sd6 sd7" "${out}"
printf 'DISK=sd8\n' > "${tmp}/answers.conf"
INSTALLER_CONF="${tmp}/openbsd.conf" INSTALLER_ANSWERS="${tmp}/answers.conf" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-openbsd.conf" \
	sections.d/disk.sh validate >/dev/null 2>&1 && rc=0 || rc=$?
check_rc "the softraid volume is not a disk to install to" 2 "${rc}"
# The hook of the OpenBSD adapter reads the same (diskprobe --assembled).
check "the arrays OpenBSD assembled" "sd8" \
	"$(python3 -I -B lib/diskprobe.py --replay tests/fixtures/captures/openbsd/10-softraid-raidframe --assembled openbsd)"
check "the arrays NetBSD assembled" "raid0" \
	"$(python3 -I -B lib/diskprobe.py --replay tests/fixtures/captures/netbsd/10-softraid-raidframe --assembled netbsd)"

# The second layer alone: a report that marks an array as assembled keeps
# it out of the disk page even when the adapter offers it (no hook, no
# ASSEMBLED, no captures).
cat > "${tmp}/assembled.json" <<'JSON'
{"disks": [{"name": "ld6", "size_bytes": 1073741824, "partitions": [], "os": [], "free": [],
            "member_of": "raid0 (RAIDframe RAID 1)"},
           {"name": "raid0", "size_bytes": 1071579136, "partitions": [], "os": [], "free": [],
            "assembled": {"kind": "RAIDframe", "level": "RAID 1", "members": ["ld6"]}}]}
JSON
printf 'DISKS=ld6|VirtIO disk|1073741824,raid0|RAIDframe raid0|1071579136\nDISKS_DETAIL=%s\nINTERFACES=em0|Example\n' \
	"${tmp}/assembled.json" > "${tmp}/assembled.conf"
out=$(INSTALLER_ADAPTER_FIXTURE="${tmp}/assembled.conf" bin/installer-apply --list disks 2>/dev/null |
	python3 -I -B -c 'import json, sys; print(" ".join(d["name"] for d in json.load(sys.stdin)["detail"]["disks"]))')
check "the disk section leaves an assembled array out by itself" "ld6" "${out}"

# A replay reads files the user names: never as root.
check_contains "the probe refuses a replay as root" "never run as root" \
	"$(grep -c 'a replay is never run as root' lib/diskprobe.py) never run as root"

finish

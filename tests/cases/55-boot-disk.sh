#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The disks that must not be written to are never offered: the disk of the
# running system and the disk of the installation media.  The device of the
# root file system names its disk in several ways and every one of them has
# to be understood.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-boot.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

cat > "${tmp}/disk-info" <<'DISKS'
ada0	Samsung SSD 860	500107862016
ada1	Samsung SSD 870	1000204886016
ada2	Crucial MX500	1000204886016
DISKS

cat > "${tmp}/zpool" <<'ZPOOL'
  pool: zroot
 state: ONLINE
config:

	NAME             STATE     READ WRITE CKSUM
	zroot            ONLINE       0     0     0
	  /dev/ada0p2    ONLINE       0     0     0

errors: No known data errors
ZPOOL

# probe_disks — the disks that are offered, as "name description" per line.
probe_disks() {
	PATH="${stubs}:${PATH}" \
	STUB_DISKS='ada0 ada1 ada2' \
	STUB_DISK_INFO="${tmp}/disk-info" \
	STUB_MOUNTS="${tmp}/mounts" \
	STUB_GLABEL="${tmp}/glabels" \
	STUB_ZFS_ROOT="${STUB_ZFS_ROOT:-}" \
	STUB_ZPOOL="${tmp}/zpool" \
	"${backend}" disk probe 2>/dev/null | python3 -I -B -c '
import json, sys
data = json.load(sys.stdin)
for disk in data["disks"]:
    print("%s %s" % (disk["name"], disk["descr"]))
' || :
}

# offered — the names of the disks that are offered.
offered() {
	probe_disks | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//'
}

# mount_table <lines...> — the mount table of the machine.
mount_table() {
	printf '%s\n' "$@" > "${tmp}/mounts"
}

# a GPT partition.
mount_table '/dev/ada0p3 / ufs rw 0 0'
check "a partition of a GPT disk is not offered" "ada1 ada2" "$(offered)"

# An MBR slice with a BSD label.
mount_table '/dev/ada0s1a / ufs rw 0 0'
check "a slice with a BSD label is not offered" "ada1 ada2" "$(offered)"

# A file system with a GEOM label.
mount_table '/dev/ufs/root / ufs rw 0 0'
printf 'ufs/root      N/A  ada0s1a\n' > "${tmp}/glabels"
check "the disk of a GEOM label is not offered" "ada1 ada2" "$(offered)"

# A partition with a GPT label.
mount_table '/dev/gpt/root / ufs rw 0 0'
printf 'gpt/root      N/A  ada0p2\n' > "${tmp}/glabels"
check "the disk of a GPT label is not offered" "ada1 ada2" "$(offered)"

# A provider with a GEOM label.
mount_table '/dev/label/root / ufs rw 0 0'
printf 'label/root    N/A  ada0p3\n' > "${tmp}/glabels"
check "the disk of a GEOM provider is not offered" "ada1 ada2" "$(offered)"

# A ZFS root.
mount_table 'zroot/ROOT/default / zfs rw 0 0'
: > "${tmp}/glabels"
STUB_ZFS_ROOT='zroot/ROOT/default'
export STUB_ZFS_ROOT
check "the disk of a ZFS pool is not offered" "ada1 ada2" "$(offered)"
unset STUB_ZFS_ROOT

# The installation media is on a disk of its own.
mount_table '/dev/ada0p3 / ufs rw 0 0' '/dev/ada1s1a /mnt ufs rw 0 0'
check "the disk of the installation media is not offered" "ada2" "$(offered)"

# The description of a disk is read from the field the tool writes in lower
# case.
mount_table '/dev/ada0p3 / ufs rw 0 0'
check_contains "the description of a disk is read" "ada2 Crucial MX500" \
	"$(probe_disks)"

# The live media of an ISO image: the root is the label of the ISO 9660
# file system, whose provider is the disk the image was written to.
mount_table '/dev/iso9660/LIVE_MEDIA / cd9660 ro 0 0'
printf 'iso9660/LIVE_MEDIA  N/A  ada1\n' > "${tmp}/glabels"
check "an ISO 9660 root (a written image) is not offered" "ada0 ada2" "$(offered)"

# A root named by the disk identifier of the disk.
mount_table '/dev/diskid/DISK-S3Z9NB0K123456p2 / ufs rw 0 0'
printf 'diskid/DISK-S3Z9NB0K123456  N/A  ada2\n' > "${tmp}/glabels"
check "a root named by its disk identifier is not offered" "ada0 ada1" "$(offered)"

# The installation media mounted on /mnt with a GPT identifier label.
mount_table '/dev/ada0p3 / ufs rw 0 0' '/dev/gptid/0b1c2d3e-0000-0000-0000-000000000001 /mnt ufs ro 0 0'
printf 'gptid/0b1c2d3e-0000-0000-0000-000000000001  N/A  ada2p1\n' > "${tmp}/glabels"
check "the media named by a GPT identifier is not offered" "ada1" "$(offered)"

# A ZFS root whose pool names its devices by labels.
cat > "${tmp}/zpool" <<'ZPOOL'
  pool: zroot
 state: ONLINE
config:

	NAME                       STATE     READ WRITE CKSUM
	zroot                      ONLINE       0     0     0
	  mirror-0                 ONLINE       0     0     0
	    /dev/gpt/zfs0          ONLINE       0     0     0
	    /dev/diskid/DISK-XYZ   ONLINE       0     0     0

errors: No known data errors
ZPOOL
mount_table 'zroot/ROOT/default / zfs rw 0 0'
printf 'gpt/zfs0  N/A  ada0p3\ndiskid/DISK-XYZ  N/A  ada1\n' > "${tmp}/glabels"
check "every labelled device of a ZFS root pool is followed" "ada2" \
	"$(STUB_ZFS_ROOT=zroot/ROOT/default offered)"

finish

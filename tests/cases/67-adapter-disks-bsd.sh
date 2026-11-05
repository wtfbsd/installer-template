#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The NetBSD, OpenBSD and DragonFly adapters read the disks and the network
# adapters from the tools of their system, with the output those tools
# print, and leave out the disk of the running system and of the media.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-bsd-disks.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

conf() {
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\n' "$1" > "${tmp}/$1.conf"
	printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' >> "${tmp}/$1.conf"
}
for os in netbsd openbsd dragonfly; do conf "${os}"; done

# names <json> <key> — the names of the items, separated by spaces.
names() {
	printf '%s' "$1" | python3 -I -B -c '
import json, sys
print(" ".join(i["name"] for i in json.load(sys.stdin)[sys.argv[1]]))' "$2"
}
# field <json> <name> <field>
field() {
	printf '%s' "$1" | python3 -I -B -c '
import json, sys
for i in json.load(sys.stdin)["disks"]:
    if i["name"] == sys.argv[1]:
        print(i[sys.argv[2]])' "$2" "$3"
}

probe() { # probe <os> <section> [VAR=value...]
	_os=$1 _section=$2
	shift 2
	env PATH="${stubs}:${PATH}" INSTALLER_CONF="${tmp}/${_os}.conf" \
		STUB_MOUNTS="${tmp}/mounts" INSTALLER_DMESG_BOOT="${tmp}/dmesg.boot" \
		STUB_DISK_INFO="${tmp}/disk-info" "$@" \
		"${backend}" "${_section}" probe 2>/dev/null || :
}

# ---------------------------------------------------------------- NetBSD
cat > "${tmp}/disk-info" <<'INFO'
wd0	unused	21474836480
wd1	unused	1000204886016
INFO
cat > "${tmp}/dmesg.boot" <<'DMESG'
wd0 at atabus0 drive 0
wd0: <WDC WD200EARS-00MVWB0>
wd0: 20480 MB, 41610 cyl, 16 head, 63 sec, 512 bytes/sect x 41943040 sectors
wd1 at atabus1 drive 0
wd1: <Samsung SSD 870>
sd0 at scsibus0 target 0 lun 0: <SanDisk, Cruzer, 1.00> disk removable
sd0: 15000 MB, 512 bytes/sect x 30720000 sectors
DMESG
# The machine runs from the USB stick sd0, on the wedge dk2.
printf '/dev/dk2 / ffs rw 0 0\n' > "${tmp}/mounts"
out=$(probe netbsd disk STUB_HW_DISKNAMES='wd0 wd1 sd0 cd0 dk0 dk1 dk2' \
	STUB_WEDGES='dk0:wd0 dk1:wd0 dk2:sd0' STUB_ROOT_DEVICE=dk2)
check "netbsd: the disks, without the boot medium, the optical drive and the wedges" \
	"wd0 wd1" "$(names "${out}" disks)"
check "netbsd: the size comes from disklabel" "21474836480" "$(field "${out}" wd0 size_bytes)"
check "netbsd: the model comes from the kernel messages" "Samsung SSD 870" \
	"$(field "${out}" wd1 descr)"
# Without disklabel the size comes from the kernel messages.
out=$(probe netbsd disk STUB_HW_DISKNAMES='wd0 sd0' STUB_ROOT_DEVICE=dk2 \
	STUB_WEDGES='dk2:sd0' STUB_DISK_INFO=/nonexistent)
check "netbsd: the size comes from the kernel messages without a label" "21474836480" \
	"$(field "${out}" wd0 size_bytes)"
# A root on a disk partition.
printf '/dev/wd1a / ffs rw 0 0\n' > "${tmp}/mounts"
out=$(probe netbsd disk STUB_HW_DISKNAMES='wd0 wd1')
check "netbsd: the disk of a root partition is left out" "wd0" "$(names "${out}" disks)"
out=$(probe netbsd network STUB_INTERFACES='wm0 lo0 re0')
check "netbsd: the network adapters, without the loopback" "wm0 re0" \
	"$(names "${out}" interfaces)"

# ---------------------------------------------------------------- OpenBSD
cat > "${tmp}/disk-info" <<'INFO'
sd0	unused	500107862016
sd1	unused	15728640000
INFO
cat > "${tmp}/dmesg.boot" <<'DMESG'
sd0 at scsibus1 targ 0 lun 0: <ATA, Samsung SSD 860, RVT0> naa.5002538e40000000
sd0: 476940MB, 512 bytes/sector, 976773168 sectors, thin
sd1 at scsibus2 targ 1 lun 0: <SanDisk, Cruzer, 1.00> removable
sd1: 15000MB, 512 bytes/sector, 30720000 sectors
nvme0: Example NVMe Controller
sd2 at scsibus3 targ 0 lun 0: <NVMe, Example 990, 1B2Q>
sd2: 953869MB, 512 bytes/sector, 1953525168 sectors
DMESG
# The root is named by its DUID: it is the USB stick sd1.
printf '1234567890abcdef.a / ffs rw 0 0\n' > "${tmp}/mounts"
out=$(probe openbsd disk \
	STUB_HW_DISKNAMES='sd0:0123456789abcdef,sd1:1234567890abcdef,cd0:,rd0:,sd2:fedcba9876543210')
check "openbsd: the disks, without the boot medium, cd and rd" "sd0 sd2" \
	"$(names "${out}" disks)"
check "openbsd: the size comes from disklabel" "500107862016" "$(field "${out}" sd0 size_bytes)"
check "openbsd: the size comes from the kernel messages without a label" \
	"1000204886016" "$(field "${out}" sd2 size_bytes)"
check "openbsd: the model comes from the kernel messages" "NVMe, Example 990, 1B2Q" \
	"$(field "${out}" sd2 descr)"
out=$(probe openbsd network STUB_INTERFACES='em0 lo0 enc0 pflog0 iwm0')
check "openbsd: the adapters from ifconfig without -l" "em0 iwm0" \
	"$(names "${out}" interfaces)"

# The kernel messages of a real NetBSD 11 (captured, with their time
# stamps): a virtio disk has no model, only the feature flags of the
# device; the model is "VirtIO disk", never the flags.
cp "${root}/tests/fixtures/hw-captures/netbsd/dmesg.out" "${tmp}/dmesg.boot"
# A root on a memory disk: no disk of the list holds it.
printf '/dev/md0a / ffs rw 0 0\n' > "${tmp}/mounts"
out=$(probe netbsd disk STUB_HW_DISKNAMES='ld0 dk0 dk1' STUB_DISK_INFO=/nonexistent)
check "netbsd: a virtio disk is a VirtIO disk" "VirtIO disk" "$(field "${out}" ld0 descr)"
check "netbsd: its size comes from the time stamped messages" "5368709120" \
	"$(field "${out}" ld0 size_bytes)"
# The same messages without the time stamps (the copy of an older boot).
sed 's/^\[ *[0-9.]*\] //' "${root}/tests/fixtures/hw-captures/netbsd/dmesg.out" > "${tmp}/dmesg.boot"
out=$(probe netbsd disk STUB_HW_DISKNAMES='ld0' STUB_DISK_INFO=/nonexistent)
check "netbsd: never the feature flags as the model" "VirtIO disk" "$(field "${out}" ld0 descr)"

# ---------------------------------------------------------------- DragonFly
cat > "${tmp}/dmesg.boot" <<'DMESG'
da0 at ahci0 bus 0 target 0 lun 0
da0: <Samsung SSD 860 RVT0> Fixed Direct Access SCSI-6 device
da0: 476940MB (976773168 512 byte sectors)
da8 at umass-sim0 bus 0 target 0 lun 0
da8: <SanDisk Cruzer 1.00> Removable Direct Access SCSI-6 device
da8: 15000MB (30720000 512 byte sectors)
DMESG
printf 'da8s1d@ROOT / hammer2 rw 0 0\n' > "${tmp}/mounts"
out=$(probe dragonfly disk STUB_DISKS='da0 da8 cd0 md0')
check "dragonfly: the disks, without the boot medium, cd and md" "da0" \
	"$(names "${out}" disks)"
check "dragonfly: the size comes from the kernel messages" "500107862016" \
	"$(field "${out}" da0 size_bytes)"
check "dragonfly: the model comes from the kernel messages" "Samsung SSD 860 RVT0" \
	"$(field "${out}" da0 descr)"
# The media mounted on /mnt is left out as well.
printf '/dev/da0s1a / ufs rw 0 0\n/dev/da8s1a /mnt ufs ro 0 0\n' > "${tmp}/mounts"
out=$(probe dragonfly disk STUB_DISKS='da0 da8 da10')
check "dragonfly: the root disk and the media are left out" "da10" \
	"$(names "${out}" disks)"
# The disk da1 holds the root; da10 is another disk and stays.
printf '/dev/da1s1a / ufs rw 0 0\n' > "${tmp}/mounts"
out=$(probe dragonfly disk STUB_DISKS='da1 da10')
check "dragonfly: da10 is not taken for a part of da1" "da10" "$(names "${out}" disks)"

# The live system of DragonFly mounts its root by label (and devfs has
# serno and part-by-uuid links too): the link is followed to its disk.
# Without size lines in the kernel messages (virtio disks print none), the
# size comes from gpt show, here the captured output of real disks.
: > "${tmp}/dmesg.boot"
cap="${root}/tests/fixtures/captures/dragonfly"
mkdir -p "${tmp}/gpt"
cp "${cap}/02-windows-linux-gpt/gpt_show_vbd2.out" "${cap}/01-blank/gpt_show_vbd1.out" "${tmp}/gpt/"
printf '/dev/part-by-label/DragonFly_LIVE@ROOT / hammer2 rw 0 0\n' > "${tmp}/mounts"
printf '/dev/part-by-label/DragonFly_LIVE\t../vbd0s2a\n' > "${tmp}/links"
out=$(probe dragonfly disk STUB_DISKS='vbd0 vbd1 vbd2' STUB_LINKS="${tmp}/links" \
	STUB_GPT_DIR="${tmp}/gpt")
check "dragonfly: a root by label is the live disk" "vbd1 vbd2" "$(names "${out}" disks)"
check "dragonfly: the size of a blank disk from gpt show" "1073741824" \
	"$(field "${out}" vbd1 size_bytes)"
check "dragonfly: the size of a GPT disk from gpt show" "4294967296" \
	"$(field "${out}" vbd2 size_bytes)"
printf '/dev/part-by-uuid/a0a0a0a0-0000-4000-8000-000000000001 / hammer2 rw 0 0\n' > "${tmp}/mounts"
printf '/dev/part-by-uuid/a0a0a0a0-0000-4000-8000-000000000001\t/dev/vbd2s1\n' > "${tmp}/links"
out=$(probe dragonfly disk STUB_DISKS='vbd0 vbd1 vbd2' STUB_LINKS="${tmp}/links" \
	STUB_GPT_DIR="${tmp}/gpt")
check "dragonfly: a root by partition uuid is followed too" "vbd0 vbd1" "$(names "${out}" disks)"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Fail closed: when an adapter cannot tell which disks hold the running
# system, the installation media or the live medium (a tool fails, a
# label, DUID, serno link, wedge or pool cannot be followed), the disk
# section refuses (exit 3) and offers no disk.  What resolves to a device
# that is not offered (a memory disk) is fine.  The live medium is read
# from /var/run/wtfbsd-live-medium (INSTALLER_LIVE_MEDIUM_FILE in the
# tests) when it is there; with LIVE_MEDIUM_REQUIRED=yes a memory root
# without it is refused.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-closed.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

conf() { # conf <os> [extra line]
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' \
		"$1" > "${tmp}/$1.conf"
	[ -z "${2:-}" ] || printf '%s\n' "$2" >> "${tmp}/$1.conf"
}
for os in freebsd netbsd openbsd dragonfly; do conf "${os}"; done
cat > "${tmp}/disk-info" <<'INFO'
ada0	Example SSD	500107862016
ada1	Example SSD	1000204886016
da0	Example USB	16000000000
INFO
: > "${tmp}/dmesg.boot"
: > "${tmp}/glabels"
: > "${tmp}/links"

# run <os> [VAR=value...] — "<exit> <offered disks>" of the disk section
# (on the machine, not a rehearsal; the tools are stand-ins).
run() {
	_os=$1
	shift
	_rc=0
	_out=$(env PATH="${stubs}:${PATH}" INSTALLER_CONF="${tmp}/${_os}.conf" \
		STUB_MOUNTS="${tmp}/mounts" STUB_GLABEL="${tmp}/glabels" STUB_ZPOOL="${tmp}/zpool" \
		STUB_LINKS="${tmp}/links" STUB_DISK_INFO="${tmp}/disk-info" \
		INSTALLER_DMESG_BOOT="${tmp}/dmesg.boot" \
		INSTALLER_LIVE_MEDIUM_FILE="${tmp}/live-medium" "$@" \
		"${backend}" disk probe 2>"${tmp}/err") || _rc=$?
	_names=$(printf '%s' "${_out}" | python3 -I -c '
import json, sys
try:
    print(" ".join(d["name"] for d in json.load(sys.stdin)["disks"]))
except ValueError:
    print("-")' 2>/dev/null)
	if [ "${_rc}" = 3 ] && ! grep -q 'cannot list disks: ' "${tmp}/err"; then
		_rc="3-without-the-reason"
	fi
	printf '%s %s\n' "${_rc}" "${_names}"
}
mounts() { printf '%s\n' "$@" > "${tmp}/mounts"; }

# ---------------------------------------------------------------- FreeBSD
fb() { run freebsd STUB_DISKS='ada0 ada1 da0' "$@"; }
mounts '/dev/ada0p2 / ufs rw 0 0'
check "freebsd control: the root disk is left out" "0 ada1 da0" "$(fb)"
check "freebsd: mount -p failing is refused" "3 -" "$(fb STUB_MOUNT_FAIL=1)"
check "the refusal says what to do next" yes \
	"$(grep -qx "installer-backend: no disk offered; check the disk tools" "${tmp}/err" && echo yes || cat "${tmp}/err")"
mounts 'zroot/ROOT/default / zfs rw 0 0'
rm -f "${tmp}/zpool"
check "freebsd: a ZFS root whose zpool status fails is refused" "3 -" "$(fb)"
printf '  pool: zroot\n state: ONLINE\nconfig:\n\n\tNAME STATE\n\tzroot ONLINE\n' > "${tmp}/zpool"
check "freebsd: a ZFS root whose pool names no device is refused" "3 -" "$(fb)"
printf '  pool: zroot\nconfig:\n\tzroot ONLINE\n\t  /dev/gpt/zfs0 ONLINE\n' > "${tmp}/zpool"
check "freebsd: a pool device whose label cannot be followed is refused" "3 -" "$(fb)"
printf 'gpt/zfs0  N/A  ada1p3\n' > "${tmp}/glabels"
check "freebsd control: a labelled pool device is followed" "0 ada0 da0" "$(fb)"
mounts '/dev/iso9660/LIVE / cd9660 ro 0 0'
: > "${tmp}/glabels"
check "freebsd: an ISO 9660 root whose label is not listed is refused" "3 -" "$(fb)"
check "freebsd: an ISO 9660 root with glabel failing is refused" "3 -" "$(fb STUB_GLABEL=/nonexistent)"
printf 'iso9660/LIVE  N/A  da0\n' > "${tmp}/glabels"
check "freebsd control: the ISO 9660 root on a stick is left out" "0 ada0 ada1" "$(fb)"
mounts '/dev/ada0p2 / ufs rw 0 0' '/dev/gptid/0b1c2d3e /mnt ufs ro 0 0'
: > "${tmp}/glabels"
check "freebsd: media on /mnt that cannot be followed is refused" "3 -" "$(fb)"
mounts '/dev/md0.uzip / ufs ro 0 0'
check "freebsd control: a memory root, nothing on /mnt: every disk is offered" "0 ada0 ada1 da0" "$(fb)"

# ---------------------------------------------------------------- NetBSD
nb() { run netbsd STUB_HW_DISKNAMES='wd0 wd1 sd0 dk2' STUB_DISK_INFO=/nonexistent "$@"; }
mounts '/dev/wd0a / ffs rw 0 0'
check "netbsd control: the root disk is left out" "0 wd1 sd0" "$(nb STUB_ROOT_DEVICE=wd0)"
check "netbsd: mount failing is refused" "3 -" "$(nb STUB_MOUNT_FAIL=1)"
mounts '/dev/dk2 / ffs rw 0 0'
check "netbsd: a wedge root whose disk dkctl cannot tell is refused" "3 -" "$(nb STUB_WEDGES='')"
check "netbsd control: the wedge is followed" "0 wd0 wd1" "$(nb STUB_WEDGES='dk2:sd0')"
mounts ''
check "netbsd: nothing on / is refused" "3 -" "$(nb)"

# ---------------------------------------------------------------- OpenBSD
ob() { run openbsd STUB_DISK_INFO=/nonexistent "$@"; }
mounts '1234567890abcdef.a / ffs rw 0 0'
check "openbsd control: the DUID root is left out" "0 sd0 sd2" \
	"$(ob STUB_HW_DISKNAMES='sd0:0123456789abcdef,sd1:1234567890abcdef,sd2:fedcba9876543210')"
check "openbsd: a DUID not in hw.disknames is refused" "3 -" \
	"$(ob STUB_HW_DISKNAMES='sd0:0123456789abcdef,sd2:fedcba9876543210')"
check "openbsd: hw.disknames failing is refused" "3 -" "$(ob STUB_HW_DISKNAMES='')"
check "openbsd: mount failing is refused" "3 -" "$(ob STUB_MOUNT_FAIL=1 STUB_HW_DISKNAMES='sd0:0123456789abcdef')"

# ---------------------------------------------------------------- DragonFly
df() { run dragonfly STUB_DISKS='vbd0 vbd1 vbd2' "$@"; }
mounts '/dev/part-by-label/LIVE@ROOT / hammer2 rw 0 0'
printf '/dev/part-by-label/LIVE\t../vbd0s2a\n' > "${tmp}/links"
check "dragonfly control: the root by label is left out" "0 vbd1 vbd2" "$(df)"
: > "${tmp}/links"
check "dragonfly: a label link that cannot be read is refused" "3 -" "$(df)"
mounts '/dev/serno/EX0001.s1a / ufs rw 0 0'
check "dragonfly: a serno link that cannot be read is refused" "3 -" "$(df)"
check "dragonfly: mount failing is refused" "3 -" "$(df STUB_MOUNT_FAIL=1)"

# ------------------------------------------------- the live medium (marker)
mounts '/dev/md0.uzip / ufs ro 0 0'
: > "${tmp}/glabels"
printf '/dev/da0\n' > "${tmp}/live-medium"
chmod 644 "${tmp}/live-medium"
check "marker: the live medium it names is left out" "0 ada0 ada1" "$(fb)"
printf '/dev/da0\n/dev/ada0\n' > "${tmp}/live-medium"
check "marker: two lines are refused" "3 -" "$(fb)"
printf '../../etc\n' > "${tmp}/live-medium"
check "marker: not the name of a device is refused" "3 -" "$(fb)"
printf '/dev/da0\n' > "${tmp}/live-medium"
chmod 666 "${tmp}/live-medium"
check "marker: writable by others is refused" "3 -" "$(fb)"
rm -f "${tmp}/live-medium"
printf '/dev/da0\n' > "${tmp}/real-medium"
chmod 644 "${tmp}/real-medium"
ln -s "${tmp}/real-medium" "${tmp}/live-medium"
check "marker: a symbolic link is refused" "3 -" "$(fb)"
rm -f "${tmp}/live-medium"

# LIVE_MEDIUM_REQUIRED (off by default): a memory root without the marker.
conf freebsd 'LIVE_MEDIUM_REQUIRED=yes'
check "LIVE_MEDIUM_REQUIRED=yes: a memory root without the marker is refused" "3 -" "$(fb)"
printf '/dev/da0\n' > "${tmp}/live-medium"
chmod 644 "${tmp}/live-medium"
check "LIVE_MEDIUM_REQUIRED=yes: with the marker the medium is left out" "0 ada0 ada1" "$(fb)"
rm -f "${tmp}/live-medium"
mounts '/dev/ada0p2 / ufs rw 0 0'
check "LIVE_MEDIUM_REQUIRED=yes: a disk root needs no marker" "0 ada1 da0" "$(fb)"
conf netbsd 'LIVE_MEDIUM_REQUIRED=yes'
mounts 'tmpfs / tmpfs rw 0 0'
check "LIVE_MEDIUM_REQUIRED=yes: a tmpfs root without the marker is refused (netbsd)" "3 -" "$(nb)"
conf freebsd
mounts '/dev/md0.uzip / ufs ro 0 0'
check "LIVE_MEDIUM_REQUIRED unset: a memory root without the marker is offered as before" \
	"0 ada0 ada1 da0" "$(fb)"

# A rehearsal on another machine only says what it cannot tell; with
# EXCLUSION=strict it refuses too.
printf 'DISKS=ada0|Example SSD|500107862016,ada1|Example SSD|1000204886016\nINTERFACES=em0|Example\n' \
	> "${tmp}/rehearsal.conf"
check "rehearsal: mount failing excludes nothing" "0 ada0 ada1" \
	"$(fb STUB_MOUNT_FAIL=1 INSTALLER_ADAPTER_FIXTURE="${tmp}/rehearsal.conf")"
printf 'EXCLUSION=strict\n' >> "${tmp}/rehearsal.conf"
check "rehearsal with EXCLUSION=strict: mount failing is refused" "3 -" \
	"$(fb STUB_MOUNT_FAIL=1 INSTALLER_ADAPTER_FIXTURE="${tmp}/rehearsal.conf")"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The DragonFly adapter: the node of devfs that names a partition.
#
# On DragonFly 6.4 the node of a label (/dev/part-by-label/<label>.a) is
# not a link: it is a device of its own, with the device number of the
# partition it names.  The link cannot be followed; the device number
# decides which disk the root is on.  A node whose number names no
# partition, or two partitions with the same number, cannot be told: the
# disk section refuses (exit 3) and offers no disk.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-dfly-devfs.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"

printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=dragonfly\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' \
	> "${tmp}/dragonfly.conf"

# The device nodes of the machine: a staged tree (INSTALLER_DEV_DIR) with
# the disks of kern.disks, their slices and their partitions, and the node
# of the label of the root.
dev="${tmp}/dev"
mkdir -p "${dev}/part-by-label"
for node in vbd0 vbd0s1 vbd0s2a vbd1 vbd1s1a part-by-label/DragonFly_v6.4.2.a; do
	: > "${dev}/${node}"
done

# The device numbers of the nodes, as stat(1) prints them: the node of
# the label has the number of the partition it names.
cat > "${tmp}/devnums" <<NUMS
${dev}/part-by-label/DragonFly_v6.4.2.a	59 2
${dev}/vbd0	59 0
${dev}/vbd0s1	59 1
${dev}/vbd0s2a	59 2
${dev}/vbd1	5a 0
${dev}/vbd1s1a	5a 1
NUMS

: > "${tmp}/dmesg.boot"
: > "${tmp}/links"

# run — "<exit code> <offered disks>" of the disk section.
run() {
	_rc=0
	_out=$(env PATH="${stubs}:${PATH}" INSTALLER_CONF="${tmp}/dragonfly.conf" \
		STUB_MOUNTS="${tmp}/mounts" STUB_LINKS="${tmp}/links" \
		STUB_DISKS='vbd0 vbd1' STUB_DEVNUMS="${tmp}/devnums" \
		INSTALLER_DEV_DIR="${dev}" INSTALLER_DMESG_BOOT="${tmp}/dmesg.boot" \
		"${backend}" disk probe 2>"${tmp}/err") || _rc=$?
	_names=$(printf '%s' "${_out}" | python3 -I -B -c '
import json, sys
try:
    print(" ".join(d["name"] for d in json.load(sys.stdin)["disks"]))
except Exception:
    print("-")' 2>/dev/null)
	printf '%s %s\n' "${_rc}" "${_names}"
}

# The root is mounted by its label and the node is a device of its own,
# with the number of the partition vbd0s2a: vbd0 is the live disk and is
# left out, vbd1 is offered.
printf '/dev/part-by-label/DragonFly_v6.4.2.a / hammer2 rw 0 0\n' > "${tmp}/mounts"
check "dragonfly: a root whose label node is a device of its own is the live disk" \
	"0 vbd1" "$(run)"

# A single user start names the root without /dev/.
printf 'part-by-label/DragonFly_v6.4.2.a / hammer2 rw 0 0\n' > "${tmp}/mounts"
check "dragonfly: a root named without /dev/ is the live disk too" "0 vbd1" "$(run)"

# The node of the label names no partition of a disk of the machine: it
# cannot be told.
printf '/dev/part-by-label/Other.a / hammer2 rw 0 0\n' > "${tmp}/mounts"
check "dragonfly: a label node whose number names no partition is refused" \
	"3 -" "$(run)"

# A serial number is a device of its own too: it names the disk it is the
# number of.
mkdir -p "${dev}/serno"
: > "${dev}/serno/EX0001"
cat >> "${tmp}/devnums" <<NUMS
${dev}/serno/EX0001	59 0
NUMS
printf '/dev/serno/EX0001.s1a / ufs rw 0 0\n' > "${tmp}/mounts"
check "dragonfly: a serial number that is a device of its own is the live disk" \
	"0 vbd1" "$(run)"

# Two partitions with the same number: it cannot be told.
: > "${dev}/vbd1s1b"
cat >> "${tmp}/devnums" <<NUMS
${dev}/vbd1s1b	59 2
NUMS
printf '/dev/part-by-label/DragonFly_v6.4.2.a / hammer2 rw 0 0\n' > "${tmp}/mounts"
check "dragonfly: two partitions with the same number are refused" "3 -" "$(run)"
rm -f "${dev}/vbd1s1b"

# For root the staged tree of device nodes is never used: the adapter runs
# as a process of its own, so it must drop the override itself.  An id(1)
# on PATH that says 0 makes the run root's (rootguard.sh trusts it for
# that direction only); the adapter then looks in the real /dev, where the
# node of the label is not, and cannot tell the live disk.
mkdir -p "${tmp}/rootbin"
printf '#!/bin/sh\necho 0\n' > "${tmp}/rootbin/id"
chmod 0755 "${tmp}/rootbin/id"
printf '/dev/part-by-label/DragonFly_v6.4.2.a / hammer2 rw 0 0\n' > "${tmp}/mounts"
_rc=0
env PATH="${tmp}/rootbin:${stubs}:${PATH}" STUB_MOUNTS="${tmp}/mounts" \
	STUB_LINKS="${tmp}/links" STUB_DISKS='vbd0 vbd1' STUB_DEVNUMS="${tmp}/devnums" \
	INSTALLER_DEV_DIR="${dev}" INSTALLER_DMESG_BOOT="${tmp}/dmesg.boot" \
	"${root}/adapters/dragonfly.sh" disks >"${tmp}/root.out" 2>"${tmp}/root.err" || _rc=$?
check "dragonfly: root never uses the staged device tree" "refused" \
	"$(if [ "${_rc}" -ne 0 ] && ! grep -q vbd1 "${tmp}/root.out"; then echo refused; else echo "rc=${_rc} $(tr '\n' ' ' < "${tmp}/root.out")"; fi)"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The DragonFly adapter: what is DragonFly's own.  The operations and the
# installation itself are in lib/adapter.sh.
#
#   disks       the names come from "sysctl -n kern.disks"; optical drives
#               (cd), memory disks (md), vnode disks (vn) and floppies are
#               left out.  The size and the model come from the kernel
#               messages ("da0: 20480MB (41943040 512 byte sectors)").  The
#               disk of / and of the installation media are left out; a
#               device under /dev/serno is followed to its disk and a
#               HAMMER2 label ("da0s1d@ROOT") names its disk before the @.
#               A node of devfs that is a device of its own (DragonFly 6.4:
#               /dev/part-by-label/<label>.a has the device number of the
#               partition it names) is followed by its device number.
#   network     "ifconfig -l"
#   keymaps     the syscons keymaps of /usr/share/syscons/keymaps
#   hash-scheme SHA-512 crypt "$6$"

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

# The directory of the device nodes of the machine: /dev in the installer.
# A test points it at a staged tree (INSTALLER_DEV_DIR); the override is
# never honoured for root, which installs for real.
dev_dir=/dev
if [ -n "${INSTALLER_DEV_DIR:-}" ] && ! installer_is_root; then
	dev_dir=${INSTALLER_DEV_DIR}
fi

os_disk_rows() {
	command -v sysctl >/dev/null 2>&1 ||
		die 3 'reading the disks needs the sysctl tool'
	for _d in $(sysctl -n kern.disks 2>/dev/null || true); do
		case "${_d}" in
			cd[0-9]*|md[0-9]*|vn[0-9]*|fd[0-9]*) continue ;;
		esac
		disk_name_valid "${_d}" || continue
		_size=$(dmesg_disk_size "${_d}") || _size=''
		# virtio disks print no size in the kernel messages: gpt show
		# lists every sector of a disk, with or without a table.
		[ -n "${_size}" ] || _size=$(gpt_disk_size "${_d}") || _size=0
		_descr=$(dmesg_disk_descr "${_d}") || _descr=''
		printf '%s\t%s\t%s\n' "${_d}" "${_descr:-${_d}}" "${_size:-0}"
	done
}

# gpt_disk_size <disk> — the size of a disk in bytes from gpt show: the
# end of its last row (512 byte sectors).
gpt_disk_size() {
	gpt show "$1" 2>/dev/null | awk '
		$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { end = $1 + $2; if (end > max) max = end }
		END { if (max > 0) printf "%.0f\n", max * 512; else exit 1 }
	'
}

# devnum <path> — the device number of a device node: the major and the
# minor number, as stat(1) prints them ("%Hr %Lr").  Nothing when the path
# is not there or stat fails.
devnum() {
	stat -L -f '%Hr %Lr' "$1" 2>/dev/null || return 1
}

# dev_path <device> — the path of a device node of the machine: the
# directory of the device nodes (dev_dir).
dev_path() {
	case "$1" in
		/dev/*) printf '%s\n' "${dev_dir}/${1#/dev/}" ;;
		*) printf '%s\n' "${dev_dir}/${1}" ;;
	esac
}

# devnum_partition <number> — the partition of a disk of kern.disks that
# has the device number <number>: the disk itself, a slice of it or a
# partition of a slice.  Nothing when no device of a disk has that number,
# or when two of them have it (it cannot be told).
devnum_partition() {
	_want=$1
	_found=''
	for _disk in $(sysctl -n kern.disks 2>/dev/null); do
		case "${_disk}" in
			''|*[!a-z0-9]*) continue ;;
		esac
		for _p in "${dev_dir}/${_disk}" "${dev_dir}/${_disk}"s*; do
			[ -e "${_p}" ] || continue
			[ -L "${_p}" ] && continue
			_num=$(devnum "${_p}") || continue
			[ "${_num}" = "${_want}" ] || continue
			# Two devices with the number: it cannot be told.
			[ -z "${_found}" ] || [ "${_found}" = "${_p##*/}" ] || return 1
			_found=${_p##*/}
		done
	done
	[ -n "${_found}" ] || return 1
	printf '%s\n' "${_found}"
}

# devfs_device <node> — the device a node of devfs names: the target of
# the link, when the node is a link; otherwise the partition of a disk of
# kern.disks that has the device number of the node (DragonFly 6.4: the
# node of a label is a device of its own, with the number of the partition
# it names).  Nothing when the node cannot be followed.
devfs_device() {
	_link=$(readlink "$1" 2>/dev/null) || _link=''
	if [ -n "${_link}" ]; then
		printf '%s\n' "${_link##*/}"
		return 0
	fi
	_num=$(devnum "$(dev_path "$1")") || return 1
	[ -n "${_num}" ] || return 1
	devnum_partition "${_num}"
}

# os_excluded_disks <names> — the disks of the root, of the installation
# media and of the live medium; a /dev/serno, part-by-label or by-uuid
# path is followed to its device.  cannot_tell (exit 3) when one of them
# cannot be told.
os_excluded_disks() {
	_boot=$(boot_devices) || exit $?
	for _dev in $(printf '%s\n' "${_boot}" | awk '{ print $2 }'); do
		[ -n "${_dev}" ] || continue
		# A single user start names the root without /dev/.
		case "${_dev}" in
			part-by-label/*|part-by-uuid/*|by-label/*|by-uuid/*|serno/*)
				_dev=/dev/${_dev}
				;;
		esac
		case "${_dev}" in
			/dev/serno/*)
				# A serial number names the disk; <serno>.s1a its
				# partition.
				_target=$(devfs_device "${_dev%.s[0-9]*}") ||
					cannot_tell "cannot follow ${_dev} to its device"
				_dev=${_target}
				;;
			# The live system mounts its root by label (or by the
			# uuid of the partition): devfs links to the device, or
			# (DragonFly 6.4) makes a device of its own with the
			# number of the partition.
			/dev/part-by-label/*|/dev/part-by-uuid/*|/dev/by-label/*|/dev/by-uuid/*)
				_target=$(devfs_device "${_dev%%@*}") ||
					cannot_tell "cannot follow ${_dev} to its device"
				_dev=${_target}
				;;
		esac
		device_disk_prefix "${_dev}" "$1" | tr '\n' ' ' || :
	done
}

os_interfaces() {
	command -v ifconfig >/dev/null 2>&1 ||
		die 3 'reading the network adapters needs the ifconfig tool'
	ifconfig -l 2>/dev/null | tr ' ' '\n' || true
}

# The keymaps of DragonFly (share/syscons/keymaps), for a system whose
# keymap directory cannot be read.
KEYMAPS_KNOWN="be.iso be.iso.acc bg.bds.ctrlcaps bg.phonetic.ctrlcaps br275.iso br275.iso.acc by.cp1131 ce.iso2 cs.latin2.qwertz danish.iso el.iso07 estonian.iso finnish.iso fr.dvorak fr.iso fr.iso.acc german.iso gr.elot.acc hr.iso hu.iso2.101keys hu.iso2.102keys icelandic.iso it.iso jp.106 lat-amer lt.iso4 norwegian.iso pl_PL.ISO8859-2 pt.iso pt.iso.acc ru.koi8-r si.iso sk.iso2 spanish.iso spanish.iso.acc swedish.iso swissfrench.iso swissgerman.iso tr.iso9.q ua.koi8-u uk.iso us.dvorak us.iso us.unix"

os_keymaps() {
	keymap_dir_rows "${INSTALLER_KEYMAP_DIR:-/usr/share/syscons/keymaps}" .kbd && return 0
	keymaps_known "/usr/share/syscons/keymaps" ${KEYMAPS_KNOWN}
}

os_hash_scheme() {
	printf 'sha512\n'
}

adapter_main "$@"

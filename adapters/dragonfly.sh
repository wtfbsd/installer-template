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
#   network     "ifconfig -l"
#   keymaps     the syscons keymaps of /usr/share/syscons/keymaps
#   hash-scheme SHA-512 crypt "$6$"

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

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

# os_excluded_disks <names> — the disks of the root, of the installation
# media and of the live medium; a /dev/serno, part-by-label or by-uuid
# path is followed to its device.  cannot_tell (exit 3) when one of them
# cannot be told.
os_excluded_disks() {
	_root=$(mounted_device_checked /) || exit $?
	[ -n "${_root}" ] || cannot_tell "nothing is mounted on /"
	_media=$(mounted_device_checked "${media_mount}") || exit $?
	_medium=$(live_medium) || exit $?
	require_medium "${_root}" "${_medium}"
	for _dev in "${_root}" "${_media}" "${_medium}"; do
		[ -n "${_dev}" ] || continue
		case "${_dev}" in
			/dev/serno/*)
				_link=$(readlink "${_dev%.s[0-9]*}" 2>/dev/null) ||
					cannot_tell "${_dev} cannot be followed to its device (readlink)"
				_dev=${_link##*/}
				;;
			# The live system mounts its root by label (or by the
			# uuid of the partition): devfs links to the device.
			/dev/part-by-label/*|/dev/part-by-uuid/*|/dev/by-label/*|/dev/by-uuid/*)
				_link=$(readlink "${_dev%%@*}" 2>/dev/null) ||
					cannot_tell "${_dev} cannot be followed to its device (readlink)"
				_dev=${_link##*/}
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

os_keymaps() {
	keymap_dir_rows "${INSTALLER_KEYMAP_DIR:-/usr/share/syscons/keymaps}" .kbd ||
		keymap_rows us.iso uk.iso german.iso fr.iso spanish.iso it.iso
}

os_hash_scheme() {
	printf 'sha512\n'
}

adapter_main "$@"

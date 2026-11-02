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
	_boot=$(boot_devices) || exit $?
	for _dev in $(printf '%s\n' "${_boot}" | awk '{ print $2 }'); do
		[ -n "${_dev}" ] || continue
		case "${_dev}" in
			/dev/serno/*)
				_link=$(readlink "${_dev%.s[0-9]*}" 2>/dev/null) ||
					cannot_tell "readlink can't follow ${_dev}"
				_dev=${_link##*/}
				;;
			# The live system mounts its root by label (or by the
			# uuid of the partition): devfs links to the device.
			/dev/part-by-label/*|/dev/part-by-uuid/*|/dev/by-label/*|/dev/by-uuid/*)
				_link=$(readlink "${_dev%%@*}" 2>/dev/null) ||
					cannot_tell "readlink can't follow ${_dev}"
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

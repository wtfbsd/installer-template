#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The NetBSD adapter: what is NetBSD's own.  The operations and the
# installation itself are in lib/adapter.sh.
#
#   disks       the names come from "sysctl -n hw.disknames"; optical
#               drives (cd), wedges (dk), memory disks (md), vnode disks
#               (vnd), cgd and floppies are left out.  The size comes from
#               disklabel(8) ("bytes/sector:" and "total sectors:") or from
#               the kernel messages; the model from the kernel messages.
#               The disk of the root file system ("sysctl -n
#               kern.root_device" and the device mount(8) shows on /) and
#               the disk of the installation media are left out; a wedge
#               (dkN) names its disk in "dkctl dkN getwedgeinfo".
#   network     "ifconfig -l"
#   keymaps     the wscons encodings
#   hash-scheme bcrypt "$2a$": the crypt(3) of NetBSD refuses "$2b$"

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

os_disk_rows() {
	command -v sysctl >/dev/null 2>&1 ||
		die 3 'reading the disks needs the sysctl tool'
	for _d in $(sysctl -n hw.disknames 2>/dev/null || true); do
		case "${_d}" in
			cd[0-9]*|dk[0-9]*|md[0-9]*|vnd[0-9]*|cgd[0-9]*|fd[0-9]*) continue ;;
		esac
		disk_name_valid "${_d}" || continue
		_size=$(disklabel_size "${_d}") || _size=''
		[ -n "${_size}" ] || _size=$(dmesg_disk_size "${_d}") || _size=0
		_descr=$(dmesg_disk_descr "${_d}") || _descr=''
		printf '%s\t%s\t%s\n' "${_d}" "${_descr:-${_d}}" "${_size:-0}"
	done
}

# wedge_parent <dkN> — the disk that holds a wedge.
wedge_parent() {
	dkctl "$1" getwedgeinfo 2>/dev/null |
		awk '{ for (i = 1; i < NF; i++) if ($i == "at") { sub(/:$/, "", $(i + 1)); print $(i + 1); exit } }'
}

# os_excluded_disks <names> — the disks of the root (kern.root_device and
# the device on /), of the installation media and of the live medium; a
# wedge (dkN) is followed to its disk.  cannot_tell (exit 3) when one of
# them cannot be told.
os_excluded_disks() {
	# kern.root_device is a second witness: the device on / decides.
	_kroot=$(sysctl -n kern.root_device 2>/dev/null) || _kroot=''
	_root=$(mounted_device_checked /) || exit $?
	[ -n "${_root}" ] || cannot_tell "nothing is mounted on /"
	_media=$(mounted_device_checked "${media_mount}") || exit $?
	_medium=$(live_medium) || exit $?
	require_medium "${_root}" "${_medium}"
	for _dev in "${_kroot}" "${_root}" "${_media}" "${_medium}"; do
		[ -n "${_dev}" ] || continue
		_dev=${_dev#/dev/}
		case "${_dev}" in
			dk[0-9]*)
				_parent=$(wedge_parent "${_dev%%[!a-z0-9]*}") || _parent=''
				[ -n "${_parent}" ] ||
					cannot_tell "the wedge ${_dev} cannot be followed to its disk (dkctl)"
				_dev=${_parent}
				;;
		esac
		device_disk_prefix "${_dev}" "$1" | tr '\n' ' ' || :
	done
}

# os_assembled_volumes <names> — the RAIDframe arrays (raidN) the kernel
# configured by itself from components on the disks.
os_assembled_volumes() {
	for _d in $1; do
		case "${_d}" in
			raid[0-9]*) printf '%s\n' "${_d}" ;;
		esac
	done
}

os_interfaces() {
	command -v ifconfig >/dev/null 2>&1 ||
		die 3 'reading the network adapters needs the ifconfig tool'
	ifconfig -l 2>/dev/null | tr ' ' '\n' || true
}

os_keymaps() {
	keymap_rows us uk de fr es it pt br sg sf be nl dk fi no sv pl hu ru ua jp gr is la tr
}

os_hash_scheme() {
	printf 'bcrypt-2a\n'
}

adapter_main "$@"

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The OpenBSD adapter: what is OpenBSD's own.  The operations and the
# installation itself are in lib/adapter.sh.
#
#   disks       "sysctl -n hw.disknames" holds name:duid pairs separated by
#               commas; optical drives (cd), RAM disks (rd), vnode disks
#               (vnd) and floppies are left out.  The size comes from
#               disklabel(8) or the kernel messages, the model from the
#               kernel messages.  The disk of / and of the installation
#               media are left out; a device named by its DUID
#               (0123456789abcdef.a) is found through hw.disknames.
#   network     the "<name>: flags=" lines of ifconfig(8), which has no -l
#   keymaps     the wscons encodings
#   hash-scheme bcrypt "$2b$"

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

# disknames — "name<TAB>duid" lines of hw.disknames.
disknames() {
	sysctl -n hw.disknames 2>/dev/null | tr ',' '\n' |
		awk -F: 'NF >= 1 && $1 != "" { print $1 "\t" $2 }'
}

os_disk_rows() {
	command -v sysctl >/dev/null 2>&1 ||
		die 3 'reading the disks needs the sysctl tool'
	disknames | while IFS="${TAB}" read -r _d _duid; do
		case "${_d}" in
			cd[0-9]*|rd[0-9]*|vnd[0-9]*|fd[0-9]*) continue ;;
		esac
		disk_name_valid "${_d}" || continue
		_size=$(disklabel_size "${_d}") || _size=''
		[ -n "${_size}" ] || _size=$(dmesg_disk_size "${_d}") || _size=0
		_descr=$(dmesg_disk_descr "${_d}") || _descr=''
		printf '%s\t%s\t%s\n' "${_d}" "${_descr:-${_d}}" "${_size:-0}"
	done
}

os_excluded_disks() {
	for _dev in "$(mounted_device /)" "$(mounted_device "${media_mount}")"; do
		[ -n "${_dev}" ] || continue
		case "${_dev}" in
			[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[a-p])
				_dev=$(disknames | awk -F '\t' -v u="${_dev%.*}" '$2 == u { print $1; exit }')
				[ -n "${_dev}" ] || continue
				;;
		esac
		device_disk_prefix "${_dev}" "$1" | tr '\n' ' ' || :
	done
}

os_interfaces() {
	command -v ifconfig >/dev/null 2>&1 ||
		die 3 'reading the network adapters needs the ifconfig tool'
	ifconfig 2>/dev/null | awk '/^[a-z]+[0-9]+: flags=/ { sub(/:$/, "", $1); print $1 }' || true
}

os_keymaps() {
	keymap_rows us uk de fr es it pt br sg sf be nl dk fi no sv pl hu ru ua jp gr is la tr
}

os_hash_scheme() {
	printf 'bcrypt\n'
}

adapter_main "$@"

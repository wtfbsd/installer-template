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

# os_excluded_disks <names> — the disks of the root, of the installation
# media and of the live medium; a disk named by its DUID is found in
# hw.disknames.  cannot_tell (exit 3) when one of them cannot be told.
os_excluded_disks() {
	_root=$(mounted_device_checked /) || exit $?
	[ -n "${_root}" ] || cannot_tell "nothing is mounted on /"
	_media=$(mounted_device_checked "${media_mount}") || exit $?
	_medium=$(live_medium) || exit $?
	require_medium "${_root}" "${_medium}"
	for _dev in "${_root}" "${_media}" "${_medium}"; do
		[ -n "${_dev}" ] || continue
		case "${_dev}" in
			[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].[a-p])
				_names=$(sysctl -n hw.disknames 2>/dev/null) ||
					cannot_tell "sysctl hw.disknames failed: the disk of ${_dev} is unknown"
				_disk=$(printf '%s\n' "${_names}" | tr ',' '\n' |
					awk -F: -v u="${_dev%.*}" '$2 == u { print $1; exit }')
				[ -n "${_disk}" ] ||
					cannot_tell "the DUID of ${_dev} is not in hw.disknames"
				_dev=${_disk}
				;;
		esac
		device_disk_prefix "${_dev}" "$1" | tr '\n' ' ' || :
	done
}

# os_assembled_volumes <names> — the softraid volumes (sdN) the kernel
# assembled by itself from chunks on the disks, as bioctl lists them.
os_assembled_volumes() {
	python3 -I "${root}/lib/diskprobe.py" --assembled openbsd 2>/dev/null || :
}

os_interfaces() {
	command -v ifconfig >/dev/null 2>&1 ||
		die 3 'reading the network adapters needs the ifconfig tool'
	ifconfig 2>/dev/null | awk '/^[a-z]+[0-9]+: flags=/ { sub(/:$/, "", $1); print $1 }' || true
}

os_keymaps() {
	keymap_rows us uk de fr es it pt br sg sf be nl dk fi no sv pl hu ru ua jp gr is la tr
}

# os_layouts — what the install command of OpenBSD takes: whole disks,
# single, softraid RAID 1, CRYPTO and RAID 1C; OpenBSD cannot start from a
# softraid RAID 5.  Data disks (a plan's data[]: each disk its own FFS on
# its mount point) are made by the install command, so the disks can be
# used separately.  Install alongside and manual partitions are not offered
# yet.
os_layouts() {
	cat <<'JSON'
{"modes": ["erase"], "data_pools": true, "not_offered": "not offered on OpenBSD yet",
 "encryption": "softraid CRYPTO", "filesystems": [["ffs", "FFS"]],
 "layouts": [
  {"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1},
  {"ident": "raid1", "title": "RAID 1 (softraid)", "min_disks": 2},
  {"ident": "crypto", "title": "Encrypted (softraid CRYPTO)", "min_disks": 1, "max_disks": 1, "encrypted": true},
  {"ident": "raid1c", "title": "RAID 1C (mirrored and encrypted)", "min_disks": 2, "encrypted": true}]}
JSON
}

os_hash_scheme() {
	printf 'bcrypt\n'
}

adapter_main "$@"

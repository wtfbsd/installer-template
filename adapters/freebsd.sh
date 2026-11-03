#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The FreeBSD adapter: it reads the disks and the network adapters from the
# machine and carries out the installation.
#
# The operations and the installation itself are in lib/adapter.sh; this
# file holds what is FreeBSD's own: how the disks, the adapters and the
# keyboard layouts are found and which crypt scheme the system accepts.
#
# How the disks are found:
#
#   The names come from sysctl(8), the variable kern.disks.  It holds the
#   names of the disks of the machine, separated by spaces.
#
#   The size comes from diskinfo(1) with the option -v.  The tool prints
#   the size of the media in a line of its own: the line whose comment
#   says "mediasize in bytes" and whose first field is the size.  geom(8)
#   is used when diskinfo(1) is not there.
#
#   The description comes from geom(8), the command "geom disk list".  The
#   line that starts with "descr" holds the description of the disk.  The
#   name of the field is matched without regard to its case.
#
#   The disks that must not be written to are left out of the list: the disk
#   of the running system and the disk of the installation media.  The
#   installer runs from the media and must not write over the system it is
#   running on.
#
#   The device of the root file system names its disk in several ways:
#
#     /dev/ada0p3       a partition of a GPT disk
#     /dev/da0s1a       a slice of an MBR disk with a BSD label
#     /dev/ufs/root     a file system with a GEOM label
#     /dev/gpt/root     a partition with a GPT label
#     /dev/label/root   a provider with a GEOM label
#     a ZFS pool        the pool of the dataset that is mounted on /
#
#   A device with a GEOM label names the device that holds it in the list
#   that "glabel status -s" prints: the columns are the name of the label,
#   its state and its component.  A ZFS root names the pool of the dataset
#   that "zfs list -H -o name /" prints, and the devices of that pool are
#   the paths that "zpool status -P" prints.
#
# Every text that comes from the machine is reduced to printable ASCII
# without a quote and without a backslash before it is put in the JSON.
#
# Set INSTALLER_ADAPTER_FIXTURE to a KEY=value file to read the hardware from
# that file instead of from the machine.  The fixture is what the test suite
# uses.  A site that rehearses the installer puts the same file next to the
# configuration file and calls it rehearsal.conf.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

# label_provider <label> — the device that holds the file system with the
# GEOM label.
#
# The labels are listed by "glabel status -s" in the columns name, state and
# component.  The component is the device that holds the label.
label_provider() {
	glabel status -s 2>/dev/null |
		awk -v want="$1" '$1 == want { print $3; exit }'
}

# resolve_device <device> — the provider of a device.  A device of a GEOM
# label class (/dev/iso9660/X, /dev/diskid/X, /dev/gptid/X, /dev/ufs/X,
# /dev/ufsid/X, /dev/gpt/X, /dev/label/X, /dev/msdosfs/X, /dev/ext2fs/X,
# /dev/ntfs/X) names its provider in "glabel status -s"; a label of a label
# is followed as well.  Every other device is printed as it is.
resolve_device() {
	_dev=$1
	_hops=0
	while [ "${_hops}" -lt 4 ]; do
		case "${_dev}" in
			/dev/*/*) : ;;
			/dev/*) break ;;
			*/*) _dev=/dev/${_dev} ;;
			*) break ;;
		esac
		case "${_dev}" in
			/dev/iso9660/*|/dev/diskid/*|/dev/gptid/*|/dev/ufs/*|/dev/ufsid/*|\
			/dev/gpt/*|/dev/label/*|/dev/msdosfs/*|/dev/ext2fs/*|/dev/ntfs/*)
				_provider=$(label_provider "${_dev#/dev/}") || _provider=''
				if [ -z "${_provider}" ]; then
					# A partition of a labelled disk: the label names
					# the disk and the partition keeps its suffix
					# (diskid/DISK-X p2 is ada0p2).
					_suffix=$(printf '%s\n' "${_dev}" |
						sed -n 's/.*\(p[0-9][0-9]*\)$/\1/p; s/.*\(s[0-9][0-9]*[a-h]\{0,1\}\)$/\1/p' | head -1)
					[ -n "${_suffix}" ] || return 0
					_provider=$(label_provider "$(printf '%s' "${_dev#/dev/}" | sed "s/${_suffix}\$//")") ||
						_provider=''
					[ -n "${_provider}" ] || return 0
					_provider=${_provider}${_suffix}
				fi
				_dev=${_provider}
				;;
			*) break ;;
		esac
		_hops=$((_hops + 1))
	done
	printf '%s\n' "${_dev}"
}

# resolve_checked <device> — resolve_device, or cannot_tell when a label
# cannot be followed (glabel fails or does not list it).
resolve_checked() {
	_rc_out=$(resolve_device "$1") || _rc_out=''
	case "${_rc_out}" in
		''|/dev/iso9660/*|/dev/diskid/*|/dev/gptid/*|/dev/ufs/*|/dev/ufsid/*|\
		/dev/gpt/*|/dev/label/*|/dev/msdosfs/*|/dev/ext2fs/*|/dev/ntfs/*)
			cannot_tell "the label $1 cannot be followed to its disk (glabel)" ;;
	esac
	printf '%s\n' "${_rc_out}"
}

# excluded_disks <disks> — the names of the disks that must not be written
# to, separated by spaces: the disks of the root (every device of the pool
# of a ZFS root), of the installation media and of the live medium.  When
# one of them cannot be told it is cannot_tell (exit 3): no disk is
# offered.  Run in a command substitution.
excluded_disks() {
	_mounts=$(mount -p 2>/dev/null) || cannot_tell "mount -p failed"
	_root=$(printf '%s\n' "${_mounts}" | awk '$2 == "/" { print $1 " " $3; exit }')
	[ -n "${_root}" ] || cannot_tell "nothing is mounted on /"
	_rdev=${_root% *} _rfs=${_root##* }
	_devs=''
	if [ "${_rfs}" = zfs ]; then
		# A ZFS root: every device of the pool of the dataset on /.
		_pool=${_rdev%%/*}
		_status=$(zpool status -P "${_pool}" 2>/dev/null) ||
			cannot_tell "zpool status of the pool ${_pool} failed"
		_vdevs=$(printf '%s\n' "${_status}" | awk '/^[[:space:]]+\/dev\// { print $1 }')
		[ -n "${_vdevs}" ] || cannot_tell "zpool status names no device of the pool ${_pool}"
		for _v in ${_vdevs}; do
			_d=$(resolve_checked "${_v}") || exit $?
			_devs="${_devs} ${_d}"
		done
	else
		_d=$(resolve_checked "${_rdev}") || exit $?
		_devs="${_devs} ${_d}"
	fi
	for _m in $(printf '%s\n' "${_mounts}" | awk -v path="${media_mount}" '$2 == path { print $1 }'); do
		_d=$(resolve_checked "${_m}") || exit $?
		_devs="${_devs} ${_d}"
	done
	_medium=$(live_medium) || exit $?
	require_medium "${_rdev}" "${_medium}"
	if [ -n "${_medium}" ]; then
		_d=$(resolve_checked "${_medium}") || exit $?
		_devs="${_devs} ${_d}"
	fi
	for _d in ${_devs}; do
		_name=$(device_disk_prefix "${_d}" "$1") || continue
		printf '%s ' "${_name}"
	done
}

# disk_size <name> — the size of the disk in bytes.
#
# The size comes from diskinfo(1) with the option -v.  The tool prints the
# size of the media in a line of its own: the line whose comment says
# "mediasize in bytes" and whose first field is the size.  geom(8) is used
# when diskinfo(1) is not there.
disk_size() {
	size=$(diskinfo -v "$1" 2>/dev/null | awk '
		/mediasize in bytes/ {
			if ($1 ~ /^[0-9]+$/) { print $1; exit }
		}
	') || size=''
	if [ -z "${size}" ]; then
		size=$(geom disk list "$1" 2>/dev/null |
			awk '/Mediasize:/ { print $2; exit }') || size=''
	fi
	case "${size}" in
		''|*[!0-9]*) size=0 ;;
	esac
	printf '%s\n' "${size}"
}

# disk_descr <name> — the description of the disk.
#
# The name of the field is matched without regard to its case: the tool
# writes it in lower case.
disk_descr() {
	descr=$(geom disk list "$1" 2>/dev/null | awk '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (tolower(line) ~ /^descr:[ \t]*/) {
				text = line
				sub(/^[^:]*:[ \t]*/, "", text)
				print text
				exit
			}
		}
	') || descr=''
	[ -n "${descr}" ] || descr=$1
	printf '%s\n' "${descr}"
}

# os_disk_rows — the disks of the machine: the names of kern.disks.
os_disk_rows() {
	if ! command -v sysctl >/dev/null 2>&1; then
		die 3 'reading the disks needs the sysctl tool'
	fi
	_disks=$(sysctl -n kern.disks 2>/dev/null || true)
	for _disk in ${_disks}; do
		# An optical drive or a memory disk is never a target.
		case "${_disk}" in
			cd[0-9]*|md[0-9]*) continue ;;
		esac
		disk_name_valid "${_disk}" || continue
		printf '%s\t%s\t%s\n' "${_disk}" "$(disk_descr "${_disk}")" \
			"$(disk_size "${_disk}")"
	done
}

os_excluded_disks() {
	excluded_disks "$1"
}

os_interfaces() {
	if ! command -v ifconfig >/dev/null 2>&1; then
		die 3 'reading the network adapters needs the FreeBSD ifconfig tool'
	fi
	ifconfig -l 2>/dev/null | tr ' ' '\n' || true
}

# os_keymaps — the vt(4) keymaps of /usr/share/vt/keymaps, or the common
# ones when the directory is not there.
os_keymaps() {
	keymap_dir_rows "${INSTALLER_KEYMAP_DIR:-/usr/share/vt/keymaps}" .kbd ||
		keymap_rows us uk de fr es it pt br ch be nl dk fi no se pl cz hu ru jp
}

os_hash_scheme() {
	printf 'sha512\n'
}

adapter_main "$@"

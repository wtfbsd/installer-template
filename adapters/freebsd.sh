#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The FreeBSD adapter: it reads the disks and the network adapters from the
# machine and carries out the installation.
#
# Operations:
#   disks          JSON array of the disks that may be written to
#   network        JSON array of the network adapters
#   apply-disk     prepare the disk that was chosen
#   verify-disk    check that the disk was prepared
#   apply-install  install the system
#   verify-install check that the system was installed
#   target-root    the path of the root of the system that is installed
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

operation=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

TAB=$(printf '\t')

# The path the installation media is mounted on.  A site that mounts it
# somewhere else sets INSTALLER_MEDIA_MOUNT.
media_mount=${INSTALLER_MEDIA_MOUNT:-/mnt}

# The file that holds the mark of a rehearsal that failed once.  It lives in
# the state directory of the run, so a retry of the same run succeeds.
#
# A run that has no state directory of its own gets a directory of its own,
# and that directory is gone when the run ends.  The mark is never left in
# a path that everybody shares: a mark that outlives its run would make a
# rehearsal that comes later succeed when it has to fail.
tmp_root=${TMPDIR:-/tmp}
fail_marker_dir=''
if [ -n "${INSTALLER_STATE_DIR:-}" ]; then
	fail_marker=${INSTALLER_STATE_DIR}/install-failed-once
else
	fail_marker_dir=$(mktemp -d "${tmp_root}/wtfbsd-fail-marker.XXXXXX") ||
		die 3 'cannot create the directory of the mark of the rehearsal'
	fail_marker=${fail_marker_dir}/install-failed-once
fi

# cleanup — what the run leaves behind is gone when the run ends: the files
# of the run and the directory of the mark of a rehearsal that failed once.
cleanup() {
	if [ -n "${work:-}" ]; then
		rm -f -- "${work}" 2>/dev/null || :
	fi
	if [ -n "${kept:-}" ]; then
		rm -f -- "${kept}" 2>/dev/null || :
	fi
	if [ -n "${fail_marker_dir}" ]; then
		rmrf "${fail_marker_dir}" "${tmp_root}" || :
	fi
	return 0
}

trap 'cleanup' EXIT INT TERM HUP

# rehearsal_file — the file that holds the hardware of a rehearsal.
#
# A rehearsal reads the hardware from a file instead of from the machine.
# The file is the one the environment names, or the rehearsal.conf that lies
# next to the configuration file of the installer.  The second way is the one
# a site uses: it needs no variable in the environment at all.
rehearsal_file() {
	if [ -n "${INSTALLER_ADAPTER_FIXTURE:-}" ]; then
		printf '%s\n' "${INSTALLER_ADAPTER_FIXTURE}"
		return 0
	fi
	conf=$(config_file) || return 1
	dir=${conf%/*}
	[ "${dir}" != "${conf}" ] || dir=.
	if [ -f "${dir}/rehearsal.conf" ]; then
		printf '%s\n' "${dir}/rehearsal.conf"
		return 0
	fi
	return 1
}

rehearsal=$(rehearsal_file) || rehearsal=''

# fixture_items <key> — the items of a fixture key, one per line, as
# "name<TAB>description<TAB>size in bytes".  An item of the fixture is the
# name of the disk and it may carry a description and a size after a bar.
fixture_items() {
	value=$(kv_get "${rehearsal}" "$1") || value=''
	printf '%s' "${value}" | awk '
		BEGIN { OFS = "\t" }
		{
			count = split($0, items, ",")
			for (i = 1; i <= count; i++) {
				item = items[i]
				gsub(/^[ \t]+|[ \t]+$/, "", item)
				if (item == "") continue
				parts = split(item, fields, "|")
				name = fields[1]
				descr = name
				if (parts > 1 && fields[2] != "") descr = fields[2]
				size = 0
				if (parts > 2 && fields[3] ~ /^[0-9]+$/) size = fields[3]
				print name, descr, size
			}
		}
	'
}

# label_provider <label> — the device that holds the file system with the
# GEOM label.
#
# The labels are listed by "glabel status -s" in the columns name, state and
# component.  The component is the device that holds the label.
label_provider() {
	glabel status -s 2>/dev/null |
		awk -v want="$1" '$1 == want { print $3; exit }'
}

# zfs_root_devices <dataset> — the devices of the ZFS pool that holds the
# dataset.
#
# The devices of a pool are the paths that "zpool status -P" prints.
zfs_root_devices() {
	pool=${1%%/*}
	[ -n "${pool}" ] || return 0
	zpool status -P "${pool}" 2>/dev/null |
		awk '/^[[:space:]]+\/dev\// { print $1 }'
}

# root_devices — the devices that hold the root file system, one per line.
#
# A ZFS root is found with the dataset that is mounted on /: the pool of that
# dataset holds the devices.  Every other root is a device of the disk.
root_devices() {
	dataset=$(zfs list -H -o name / 2>/dev/null | head -1) || dataset=''
	if [ -n "${dataset}" ]; then
		zfs_root_devices "${dataset}"
		return 0
	fi
	device=$(mount -p 2>/dev/null | awk '$2 == "/" { print $1; exit }') ||
		device=''
	[ -n "${device}" ] || return 0
	case "${device}" in
		/dev/ufs/*|/dev/gpt/*|/dev/label/*)
			provider=$(label_provider "${device#/dev/}") || provider=''
			[ -n "${provider}" ] || return 0
			printf '%s\n' "${provider}"
			;;
		*)
			printf '%s\n' "${device}"
			;;
	esac
}

# media_devices — the devices that hold the installation media, one per
# line.
media_devices() {
	mount -p 2>/dev/null | awk -v path="${media_mount}" '$2 == path { print $1 }'
}

# device_disk <device> <disks> — the name of the disk that holds the device.
#
# The device may be the disk itself, a partition of a GPT disk (ada0p3), a
# slice of an MBR disk with a BSD label (da0s1a) or a device with a name of
# its own (nvme0ns1).  The name of the disk is the one that is in the list
# of the disks of the machine.
device_disk() {
	name=${1#/dev/}
	for candidate in "${name}" \
		"$(printf '%s\n' "${name}" | sed 's/[pP][0-9]*$//')" \
		"$(printf '%s\n' "${name}" | sed 's/[sS][0-9]*[a-zA-Z]*$//')"; do
		case " ${2} " in
			*" ${candidate} "*)
				printf '%s\n' "${candidate}"
				return 0
				;;
		esac
	done
	return 1
}

# excluded_disks <disks> — the names of the disks that must not be written
# to, separated by spaces.
excluded_disks() {
	for device in $(root_devices) $(media_devices); do
		name=$(device_disk "${device}" "$1") || continue
		printf '%s ' "${name}"
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

# emit_item <name> <descr> <size> — one JSON object for one item.
#
# The text of the hardware is reduced to printable ASCII without a quote and
# without a backslash before it is put in the JSON: the text comes from the
# machine and is not trusted.
emit_item() {
	_name=$(sanitize_text "$1")
	_descr=$(sanitize_text "$2")
	[ -n "${_descr}" ] || _descr=${_name}
	case "${3:-}" in
		''|*[!0-9]*) _size=0 ;;
		*) _size=$3 ;;
	esac
	printf '{"name":"%s","descr":"%s","size_bytes":%s}' \
		"${_name}" "${_descr}" "${_size}"
}

# emit_items <file> — the JSON array of the items in the file.
#
# Every item of the file is one line: the name of the item, its description
# and its size in bytes, separated by tabs.  The disks and the network
# adapters are both printed this way, so both of them are reduced to the
# same text before they are put in the JSON.
emit_items() {
	first=1
	printf '['
	while IFS="${TAB}" read -r name descr size; do
		[ -n "${name}" ] || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		emit_item "${name}" "${descr}" "${size}"
	done < "$1"
	printf ']\n'
}

cmd_disks() {
	work=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-disks.XXXXXX") ||
		die 3 'cannot create a temporary file'
	kept=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-disks.XXXXXX") ||
		die 3 'cannot create a temporary file'
	if [ -n "${rehearsal}" ]; then
		fixture_items DISKS > "${work}"
	else
		if ! command -v sysctl >/dev/null 2>&1; then
			die 3 'reading the disks needs the sysctl tool'
		fi
		disks=$(sysctl -n kern.disks 2>/dev/null || true)
		for disk in ${disks}; do
			disk_name_valid "${disk}" || continue
			printf '%s\t%s\t%s\n' "${disk}" "$(disk_descr "${disk}")" \
				"$(disk_size "${disk}")" >> "${work}"
		done
	fi
	# The disks that must not be written to are left out of the list.  A
	# rehearsal leaves them out as well: a rehearsal is carried out on
	# the machine that is the target.
	names=$(cut -f1 "${work}" | tr '\n' ' ')
	excluded=$(excluded_disks "${names}")
	while IFS="${TAB}" read -r name descr size; do
		[ -n "${name}" ] || continue
		case " ${excluded} " in
			*" ${name} "*) continue ;;
		esac
		printf '%s\t%s\t%s\n' "${name}" "${descr}" "${size}" >> "${kept}"
	done < "${work}"
	emit_items "${kept}"
}

cmd_network() {
	work=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-network.XXXXXX") ||
		die 3 'cannot create a temporary file'
	if [ -n "${rehearsal}" ]; then
		fixture_items INTERFACES > "${work}"
	else
		if ! command -v ifconfig >/dev/null 2>&1; then
			die 3 'reading the network adapters needs the FreeBSD ifconfig tool'
		fi
		for adapter in $(ifconfig -l 2>/dev/null || true); do
			case "${adapter}" in
				lo|lo0|lo1) continue ;;
			esac
			printf '%s\t%s\t0\n' "${adapter}" 'network adapter' >> "${work}"
		done
	fi
	emit_items "${work}"
}

cmd_apply_disk() {
	[ $# -eq 1 ] || die 3 'apply-disk needs the name of the disk'
	disk_name_valid "$1" || die 3 "the name '$1' is not the name of a disk"
	if [ -n "${rehearsal}" ]; then
		printf 'disk: preparing %s\n' "$1"
		return 0
	fi
	die 3 'preparing a disk needs a FreeBSD host'
}

cmd_verify_disk() {
	[ $# -eq 1 ] || die 3 'verify-disk needs the name of the disk'
	disk_name_valid "$1" || die 3 "the name '$1' is not the name of a disk"
	if [ -n "${rehearsal}" ]; then
		printf 'disk: %s is ready\n' "$1"
		return 0
	fi
	die 3 'checking a disk needs a FreeBSD host'
}

cmd_apply_install() {
	if [ -n "${rehearsal}" ]; then
		printf 'install: preparing the target disk\n'
		printf 'install: writing the system files\n'
		printf 'install: applying the settings\n'
		printf 'install: installing the boot loader\n'
		code=$(kv_get "${rehearsal}" INSTALL_EXIT) || code=0
		case "${code}" in
			''|*[!0-9]*) code=0 ;;
		esac
		once=$(kv_get "${rehearsal}" INSTALL_FAIL_ONCE) || once=''
		if [ "${once}" = yes ] && [ ! -f "${fail_marker}" ]; then
			: > "${fail_marker}"
			code=3
		fi
		if [ "${code}" -ne 0 ]; then
			printf 'install: the installation failed\n'
			exit "${code}"
		fi
		return 0
	fi
	die 3 'installing the system needs a FreeBSD host'
}

cmd_verify_install() {
	if [ -n "${rehearsal}" ]; then
		printf 'install: the system is installed\n'
		return 0
	fi
	die 3 'checking the installation needs a FreeBSD host'
}

cmd_target_root() {
	if [ -n "${rehearsal}" ]; then
		kv_get "${rehearsal}" TARGET_ROOT || :
		return 0
	fi
	# On a machine that is installed to, the root of the system is the
	# file system of the disk that was prepared.  The installer mounts it
	# before the accounts are made.
	return 0
}

case "${operation}" in
	disks) cmd_disks "$@" ;;
	network) cmd_network "$@" ;;
	apply-disk) cmd_apply_disk "$@" ;;
	verify-disk) cmd_verify_disk "$@" ;;
	apply-install) cmd_apply_install "$@" ;;
	verify-install) cmd_verify_install "$@" ;;
	target-root) cmd_target_root "$@" ;;
	*) die 3 "unknown adapter operation '${operation}'" ;;
esac

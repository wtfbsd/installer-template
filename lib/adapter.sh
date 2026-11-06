# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The part of an adapter that is the same on every system.  An adapter sets
# "root", sources lib/backend.sh, lib/config.sh and this file, defines its
# hooks and calls adapter_main "$@".
#
# The hooks of a system:
#
#   os_disk_rows                 print "name<TAB>description<TAB>bytes" for
#                                every disk of the machine
#   os_excluded_disks <names>    print the names of the disks that must not
#                                be written to (the running system and the
#                                installation media), separated by spaces;
#                                exit non-zero (cannot_tell) when it cannot
#                                tell them: then no disk is offered
#   os_interfaces                print the names of the network adapters,
#                                one per line
#   os_keymaps                   print "name<TAB>description" for every
#                                keyboard layout the system knows
#   os_assembled_volumes <names> print the disks of the list that are
#                                arrays the system assembled by itself
#                                (optional)
#   os_hash_scheme               print the crypt scheme the system accepts
#                                (sha512, bcrypt or bcrypt-2a)
#
# Operations (the adapter contract of README.md):
#
#   disks, network, apply-disk, verify-disk, apply-install, verify-install,
#   target-root, keymaps, timezones, hash-scheme
#
# The installation itself is done by the install command of the template,
# "<PRODUCT_SLUG>-install" (or INSTALLER_INSTALL_COMMAND):
#
#   <slug>-install -d DISK -u USER [-k PUBKEYFILE] -H HASHFILE [-n HOSTNAME]
#                  [-z TIMEZONE] [-K KEYMAP] [-c FULLNAME] [-P]
#                  [-N IF:ADDR/MASK:GW | -N IF:dhcp] -y --progress
#
# It prints "PROGRESS <0-100> <message>" lines and "ERROR <message>" before
# a non-zero exit.  The adapter passes those lines on unchanged.
#
# Optional: "<slug>-install --capabilities" prints what the command can do
# with disks, as JSON in the shape of os_layouts (layouts, filesystems,
# modes, data_pools, boot, encryption, not_offered).  When the installed
# command answers with a valid object, the verb layouts reports that
# instead of the adapter's built-in os_layouts; when it does not (an older
# command, an error, not JSON), the adapter falls back without a word.

. "${root}/lib/ipv4.sh"

TAB=$(printf '\t')

# The path the installation media is mounted on.
media_mount=${INSTALLER_MEDIA_MOUNT:-/mnt}

# The file that holds the mark of a rehearsal that failed once.  It lives in
# the state directory of the run, so a retry of the same run succeeds.  A
# run without a state directory gets a directory of its own that is gone
# when the run ends: a mark that outlives its run would make a later
# rehearsal succeed when it has to fail.
tmp_root=${TMPDIR:-/tmp}
fail_marker_dir=''
fail_marker=''

work=''
kept=''

# The temporary files of the run that the cleanup has to know about.
# Every file of the run is named in one of them, so that the cleanup
# removes it: a run that is interrupted must leave nothing behind.
install_err=''
install_pipe=''
disk_rows=''

# The process of the install command, while it runs.
install_pid=''

# cleanup — the files of the run, the pipe of the install command and the
# directory of the mark are gone when the run ends, whatever the way the
# run ends.  It may be called twice: the handler of a signal calls it
# and the trap of the exit calls it again.
cleanup() {
	if [ -n "${work:-}" ]; then
		rm -f -- "${work}" 2>/dev/null || :
		work=''
	fi
	if [ -n "${kept:-}" ]; then
		rm -f -- "${kept}" 2>/dev/null || :
		kept=''
	fi
	if [ -n "${install_err:-}" ]; then
		rm -f -- "${install_err}" "${install_err}.seen" 2>/dev/null || :
		install_err=''
	fi
	if [ -n "${install_pipe:-}" ]; then
		rm -f -- "${install_pipe}" 2>/dev/null || :
		install_pipe=''
	fi
	if [ -n "${disk_rows:-}" ]; then
		rm -f -- "${disk_rows}" 2>/dev/null || :
		disk_rows=''
	fi
	if [ -n "${fail_marker_dir}" ]; then
		rmrf "${fail_marker_dir}" "${tmp_root}" || :
	fi
	return 0
}

# signal_exit <code> — the run was interrupted: the files of the run are
# gone and the run ends with the code of the signal (129 for HUP, 130 for
# INT and 143 for TERM).
#
# A signal needs a handler of its own: a handler that cleans up and
# returns leaves the script running.
signal_exit() {
	trap - EXIT HUP INT TERM
	# The files of the run go first: stopping the command takes up to two
	# seconds, and a second interrupt in between must find nothing left.
	cleanup
	stop_install_command
	exit "$1"
}

# stop_install_command — the install command and every process it started
# are stopped, so that nothing keeps writing to the target after the run
# was interrupted: TERM to its group, KILL two seconds later for what did
# not stop.  The command is a child that is not reaped yet, so the number
# of its group cannot belong to another group in between.
stop_install_command() {
	if [ -n "${install_pid:-}" ]; then
		kill -TERM "-${install_pid}" 2>/dev/null ||
			kill -TERM "${install_pid}" 2>/dev/null || :
		sleep 2
		kill -KILL "-${install_pid}" 2>/dev/null ||
			kill -KILL "${install_pid}" 2>/dev/null || :
		wait "${install_pid}" 2>/dev/null || :
		install_pid=''
	fi
	return 0
}

# setup_fail_marker — where the mark of a rehearsal that failed once lives.
setup_fail_marker() {
	if [ -n "${INSTALLER_STATE_DIR:-}" ]; then
		fail_marker=${INSTALLER_STATE_DIR}/install-failed-once
	else
		fail_marker_dir=$(mktemp -d "${tmp_root}/wtfbsd-fail-marker.XXXXXX") ||
			die 3 'cannot create the directory of the mark of the rehearsal'
		fail_marker=${fail_marker_dir}/install-failed-once
	fi
}

# rehearsal_file — the file that holds the hardware of a rehearsal: the one
# the environment names, or rehearsal.conf next to the configuration file.
rehearsal_file() {
	# A rehearsal is never carried out as root: root installs for real.
	if installer_is_root; then
		return 1
	fi
	if [ -n "${INSTALLER_ADAPTER_FIXTURE:-}" ]; then
		printf '%s\n' "${INSTALLER_ADAPTER_FIXTURE}"
		return 0
	fi
	_conf=$(config_file) || return 1
	_dir=${_conf%/*}
	[ "${_dir}" != "${_conf}" ] || _dir=.
	if [ -f "${_dir}/rehearsal.conf" ]; then
		printf '%s\n' "${_dir}/rehearsal.conf"
		return 0
	fi
	return 1
}

# fixture_items <key> — the items of a fixture key, one per line, as
# "name<TAB>description<TAB>size in bytes".
fixture_items() {
	_value=$(kv_get "${rehearsal}" "$1") || _value=''
	printf '%s' "${_value}" | awk '
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

# emit_item <name> <descr> <size> — one JSON object.  The text comes from the
# machine and is reduced to printable ASCII without a quote and without a
# backslash first.
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

# emit_items <file> — the JSON array of the "name<TAB>descr<TAB>size" lines.
emit_items() {
	_first=1
	printf '['
	while IFS="${TAB}" read -r _n _d _s; do
		[ -n "${_n}" ] || continue
		[ "${_first}" -eq 1 ] || printf ','
		_first=0
		emit_item "${_n}" "${_d}" "${_s}"
	done < "$1"
	printf ']\n'
}

# device_disk_prefix <device> <disks> — the disk of the list that holds the
# device: the disk itself or a disk followed by a partition or slice suffix
# (wd0a, sd0a, da0s1d, ada0p3).  A disk name is never followed by a digit,
# so sd1 is never taken for a part of sd10.
device_disk_prefix() {
	_dev=${1#/dev/}
	_dev=${_dev#r}
	_dev=${_dev%%@*}
	for _cand in $2; do
		case "${_dev}" in
			"${_cand}") printf '%s\n' "${_cand}"; return 0 ;;
			"${_cand}"[!0-9]*) printf '%s\n' "${_cand}"; return 0 ;;
		esac
	done
	# The device may be named without the leading r of a raw device.
	_dev=${1#/dev/}
	for _cand in $2; do
		case "${_dev}" in
			"${_cand}"|"${_cand}"[!0-9]*) printf '%s\n' "${_cand}"; return 0 ;;
		esac
	done
	return 1
}

# cannot_tell <reason> — the disks of the running system or of the media
# cannot be told: exit 3, and no disk is offered (fail closed).  A
# rehearsal (on a machine that is not the target, which it never writes
# to) only says so, unless its fixture asks for EXCLUSION=strict.
cannot_tell() {
	printf 'cannot list disks: %s\n' "$*" >&2
	if [ -n "${rehearsal:-}" ] && [ "$(kv_get "${rehearsal}" EXCLUSION 2>/dev/null || :)" != strict ]; then
		exit 0
	fi
	exit 3
}

# boot_devices [-p] — the devices the running system needs, as they are
# named, one a line: "root <device> <type>" (the file system on /),
# "media <device>" (on the media mount point; none or more) and "medium
# <device>" (live_medium); the adapter follows each to its disk.  -p reads
# the table of "mount -p" (FreeBSD), else the "<device> on <path> type
# <type>" lines of mount(8).  cannot_tell when mount fails, nothing is on
# /, or a memory root lacks its medium (require_medium).  Run it in a
# command substitution and pass its exit on: x=$(boot_devices) || exit $?
boot_devices() {
	if [ "${1:-}" = -p ]; then
		_mt=$(mount -p 2>/dev/null) || cannot_tell "mount -p failed"
		_bd_root=$(printf '%s\n' "${_mt}" | awk '$2 == "/" { print $1 " " $3; exit }')
		_bd_media=$(printf '%s\n' "${_mt}" | awk -v p="${media_mount}" '$2 == p { print $1 }')
	else
		_mt=$(mount 2>/dev/null) || cannot_tell "mount failed"
		_bd_root=$(printf '%s\n' "${_mt}" | awk '$2 == "on" && $3 == "/" { print $1 " " $5; exit }')
		_bd_media=$(printf '%s\n' "${_mt}" |
			awk -v p="${media_mount}" '$2 == "on" && $3 == p { print $1 }')
	fi
	[ -n "${_bd_root}" ] || cannot_tell "nothing mounted on /"
	_bd_medium=$(live_medium) || exit $?
	require_medium "${_bd_root% *}" "${_bd_medium}"
	printf 'root %s\n' "${_bd_root}"
	for _m in ${_bd_media}; do
		printf 'media %s\n' "${_m}"
	done
	[ -z "${_bd_medium}" ] || printf 'medium %s\n' "${_bd_medium}"
}

# The file a live system writes at its start: one line, the device it was
# started from (the live medium).  Root-owned, a regular file.
live_medium_file=${INSTALLER_LIVE_MEDIUM_FILE:-/var/run/wtfbsd-live-medium}

# live_medium — the device of the live medium, from live_medium_file;
# nothing when the file is not there; cannot_tell when it is there but
# cannot be trusted (a link, not a regular file, not root's, writable by
# others, more than one line or not the name of a device).
live_medium() {
	[ -e "${live_medium_file}" ] || [ -L "${live_medium_file}" ] || return 0
	_lm=$(python3 -I -B - "${live_medium_file}" <<'PY'
import os, re, stat, sys
path = sys.argv[1]
st = os.lstat(path)
uid = os.geteuid()
if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o022 or st.st_size > 256 or \
        not (st.st_uid == 0 or (uid != 0 and st.st_uid == uid)):
    sys.exit(1)
with open(path, encoding="ascii", errors="strict") as stream:
    lines = stream.read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
dev = lines[0] if len(lines) == 1 else ""
if not re.fullmatch(r"(/dev/)?[A-Za-z0-9][A-Za-z0-9._/-]{0,127}", dev, re.ASCII) or ".." in dev:
    sys.exit(1)
print(dev)
PY
) || cannot_tell "untrusted ${live_medium_file}"
	printf '%s\n' "${_lm}"
}

# memory_root <device> — succeed when the root is a memory or overlay file
# system (md, rd, tmpfs, unionfs, mfs): the disk it came from is the medium.
memory_root() {
	case "${1#/dev/}" in
		md[0-9]*|rd[0-9]*|tmpfs|unionfs|mfs|mfs:*|union|ramdisk*) return 0 ;;
	esac
	return 1
}

# require_medium <root device> <medium> — with LIVE_MEDIUM_REQUIRED=yes, a
# memory or overlay root without the name of its medium is cannot_tell.
require_medium() {
	memory_root "$1" || return 0
	[ -z "$2" ] || return 0
	[ "$(config_value LIVE_MEDIUM_REQUIRED 2>/dev/null || :)" = yes ] || return 0
	cannot_tell "the boot medium can't be found (no ${live_medium_file})"
}


# dmesg_text — the kernel messages: the running buffer and the boot copy.
dmesg_text() {
	dmesg 2>/dev/null || :
	cat "${INSTALLER_DMESG_BOOT:-/var/run/dmesg.boot}" 2>/dev/null || :
}

# dmesg_disk_descr <name> — the model of the disk in the kernel messages:
# "sd0 at scsibus1 ...: <ATA, Model, 1.0>" or "wd0: <Model>".
dmesg_disk_descr() {
	dmesg_text | awk -v d="$1" '
		# NetBSD stamps every line with the time: "[     1.010953] ".
		{ sub(/^\[ *[0-9.]+\] /, "") }
		index($0, d ":") == 1 || index($0, d " at ") == 1 {
			# "ld0 at virtio0: features: 0x...<INDIRECT_DESC,...>" names the
			# flags of a virtio device, not a model.
			if ($0 ~ /features: 0x/) {
				if (index($0, d " at virtio") == 1) virtio = 1
				next
			}
			if (index($0, d " at virtio") == 1) virtio = 1
			s = index($0, "<"); e = index($0, ">")
			if (s > 0 && e > s) { print substr($0, s + 1, e - s - 1); found = 1; exit }
		}
		END { if (!found && virtio) print "VirtIO disk" }
	'
}

# dmesg_disk_size <name> — the size of the disk in bytes from the kernel
# messages.  The systems write it in three ways:
#   da0: 20480MB (41943040 512 byte sectors)                  DragonFly
#   wd0: 20 GB, ..., 512 bytes/sect x 41943040 sectors       NetBSD
#   sd0: 20480MB, 512 bytes/sector, 41943040 sectors          OpenBSD
dmesg_disk_size() {
	dmesg_text | awk -v d="$1" '
		{ sub(/^\[ *[0-9.]+\] /, "") }
		index($0, d ":") != 1 { next }
		match($0, /\([0-9]+ [0-9]+ byte sectors/) {
			split(substr($0, RSTART + 1, RLENGTH - 1), f, " ")
			printf "%.0f\n", f[1] * f[2]; exit
		}
		match($0, /[0-9]+ bytes\/sect x [0-9]+ sectors/) {
			split(substr($0, RSTART, RLENGTH), f, " ")
			printf "%.0f\n", f[1] * f[4]; exit
		}
		match($0, /[0-9]+ bytes\/sector, [0-9]+ sectors/) {
			split(substr($0, RSTART, RLENGTH), f, " ")
			printf "%.0f\n", f[1] * f[3]; exit
		}
	'
}

# disklabel_size <name> — the size in bytes from disklabel(8) (NetBSD,
# OpenBSD): the "bytes/sector:" and "total sectors:" lines.
disklabel_size() {
	disklabel "$1" 2>/dev/null | awk '
		/^bytes\/sector:/ { b = $2 }
		/^total sectors:/ { s = $3 }
		END { if (b > 0 && s > 0) printf "%.0f\n", b * s }
	'
}

# keymap_descr <name> — the name of the country of a layout.
keymap_descr() {
	_k=${1%.kbd}
	_k=${_k%%.*}
	case "${_k}" in
		us) printf 'United States\n' ;;
		uk|gb) printf 'United Kingdom\n' ;;
		de|german) printf 'Germany\n' ;;
		sg) printf 'Switzerland (German)\n' ;;
		fr|french) printf 'France\n' ;;
		es|spanish) printf 'Spain\n' ;;
		it|italian) printf 'Italy\n' ;;
		pt|portuguese) printf 'Portugal\n' ;;
		br) printf 'Brazil\n' ;;
		ch|swiss) printf 'Switzerland\n' ;;
		sf) printf 'Switzerland (French)\n' ;;
		be|belgian) printf 'Belgium\n' ;;
		nl|dutch) printf 'Netherlands\n' ;;
		dk|danish) printf 'Denmark\n' ;;
		fi|finnish) printf 'Finland\n' ;;
		no|norwegian) printf 'Norway\n' ;;
		se|sv|swedish) printf 'Sweden\n' ;;
		pl|polish) printf 'Poland\n' ;;
		cz|czech) printf 'Czech Republic\n' ;;
		hu|hungarian) printf 'Hungary\n' ;;
		ru|russian) printf 'Russia\n' ;;
		ua|ukrainian) printf 'Ukraine\n' ;;
		jp|jp106|japanese) printf 'Japan\n' ;;
		tr|turkish) printf 'Turkey\n' ;;
		gr|greek) printf 'Greece\n' ;;
		is|icelandic) printf 'Iceland\n' ;;
		la|latinamerican) printf 'Latin America\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# keymap_rows <names...> — "name<TAB>description" for every name.
keymap_rows() {
	for _k in "$@"; do
		printf '%s\t%s\n' "${_k}" "$(keymap_descr "${_k}")"
	done
}

# keymap_dir_rows <dir> <suffix> — the layouts of a directory of keymap
# files, the suffix removed.  Fails when the directory has none.
keymap_dir_rows() {
	[ -d "$1" ] || return 1
	_found=0
	for _f in "$1"/*"$2"; do
		[ -f "${_f}" ] || continue
		_n=${_f##*/}
		_n=${_n%"$2"}
		printf '%s\n' "${_n}" | grep -Eq '^[A-Za-z0-9._-]{1,32}$' || continue
		printf '%s\t%s\n' "${_n}" "$(keymap_descr "${_n}")"
		_found=1
	done
	[ "${_found}" -eq 1 ]
}

# keymaps_known <dir> <name...> — the keymaps the adapter knows for its
# system, when the directory of the system cannot be read: a broken image
# (said in the log), but never a short choice.  A rehearsal says nothing.
keymaps_known() {
	_kdir=$1
	shift
	[ -n "${rehearsal:-}" ] ||
		printf 'warning: the keymaps of the system (%s) cannot be read; the installer uses its own list\n' "${_kdir}" >&2
	keymap_rows "$@"
}

# zone_rows — "name<TAB>description" for the time zones of the system, from
# zone1970.tab or zone.tab of the zoneinfo directory (os_zoneinfo_dir of the
# adapter, else /usr/share/zoneinfo).  UTC comes first.
zone_rows() {
	_tab=${1:-}
	if [ -z "${_tab}" ]; then
		_tab=$(zone_table) || {
			# A system without a readable zone table is a broken image:
			# say so, and offer every zone of the installer's own table.
			printf 'warning: the zone table of the system cannot be read; the installer uses its own (lib/zone1970.tab)\n' >&2
			_tab="${root}/lib/zone1970.tab"
		}
	fi
	printf 'UTC\tCoordinated Universal Time\n'
	# The names of the countries: the table next to the zone table (tzdb
	# iso3166.tab; illumos tab/country.tab), else the installer's own.
	_ct="${root}/lib/iso3166.tab"
	for _c in "${_tab%/*}/iso3166.tab" "${_tab%/*}/country.tab"; do
		if [ "${_tab}" != "${root}/lib/zone1970.tab" ] && [ -f "${_c}" ]; then
			_ct=${_c}
			break
		fi
	done
	zone_list "${_tab}" "${_ct}"
}

# zone_table — the zone table of the system: zone1970.tab or zone.tab of
# its zoneinfo directory (os_zoneinfo_dir, else /usr/share/zoneinfo); false
# when there is none.
zone_table() {
	_zi=${INSTALLER_ZONEINFO:-}
	if [ -z "${_zi}" ]; then
		if command -v os_zoneinfo_dir >/dev/null 2>&1; then
			_zi=$(os_zoneinfo_dir)
		else
			_zi=/usr/share/zoneinfo
		fi
	fi
	_tab=''
	# illumos keeps its tables in tab/ (zone_sun.tab has the columns of
	# zone.tab).
	for _t in "${_zi}/zone1970.tab" "${_zi}/zone.tab" "${_zi}/tab/zone_sun.tab" \
		"${_zi}/tab/zone.tab"; do
		if [ -f "${_t}" ]; then
			_tab=${_t}
			break
		fi
	done
	[ -n "${_tab}" ] || return 1
	printf '%s\n' "${_tab}"
}

# target_rows <file> — the rows of the disks that may be written to, into
# a file.
target_rows() {
	kept=$1
	work=$(mktemp "${tmp_root}/wtfbsd-disks.XXXXXX") ||
		die 3 'cannot create a temporary file'
	if [ -n "${rehearsal}" ]; then
		fixture_items DISKS > "${work}"
	else
		os_disk_rows > "${work}"
	fi
	# The disks that must not be written to are left out, in a rehearsal
	# too: a rehearsal is carried out on the machine that is the target.
	_names=$(cut -f1 "${work}" | tr '\n' ' ')
	# An adapter that cannot tell which disks hold the running system or
	# the media (cannot_tell, or any other failure) offers none: never a
	# disk it may not write to.
	_excluded=$(os_excluded_disks "${_names}") ||
		die 3 'no disk offered; check the disk tools'
	# An array the system assembled by itself from members found on the
	# disks (NetBSD RAIDframe raidN, OpenBSD softraid sdN) is not offered:
	# its members are, as members of it.  A rehearsal names them in
	# ASSEMBLED.
	if [ -n "${rehearsal}" ]; then
		_excluded="${_excluded} $(kv_get "${rehearsal}" ASSEMBLED | tr ',' ' ')" || :
		# A rehearsal on captured outputs reads the arrays from them.
		if _cap=$(kv_get "${rehearsal}" DISKS_CAPTURE) && [ -n "${_cap}" ]; then
			_excluded="${_excluded} $(python3 -I -B "${root}/lib/diskprobe.py" \
				--base "${rehearsal%/*}" --replay "${_cap}" --assembled "$(config_value OS)" |
				tr '\n' ' ')" || :
		fi
	elif command -v os_assembled_volumes >/dev/null 2>&1; then
		_excluded="${_excluded} $(os_assembled_volumes "${_names}" | tr '\n' ' ')" || :
	fi
	while IFS="${TAB}" read -r _n _d _s; do
		[ -n "${_n}" ] || continue
		disk_name_valid "${_n}" || continue
		case " ${_excluded} " in
			*" ${_n} "*) continue ;;
		esac
		printf '%s\t%s\t%s\n' "${_n}" "${_d}" "${_s}" >> "${kept}"
	done < "${work}"
	rm -f "${work}"
}

cmd_disks() {
	_rows=$(mktemp "${tmp_root}/wtfbsd-disks.XXXXXX") ||
		die 3 'cannot create a temporary file'
	disk_rows=${_rows}
	# A rehearsal of a slow system: PROBE_DELAY seconds (at most 30)
	# before the list, as reading the disks of some systems takes.
	if [ -n "${rehearsal}" ] && _delay=$(kv_get "${rehearsal}" PROBE_DELAY); then
		case "${_delay}" in
			[0-9]|[12][0-9]|30) sleep "${_delay}" ;;
		esac
	fi
	target_rows "${_rows}"
	emit_items "${_rows}"
	rm -f "${_rows}"
	disk_rows=''
}

# cmd_disks_detail — the report of the disks the disk page shows: model,
# size, serial, bus, SSD, health, partitions, the operating systems found
# on them and their free space, with the boot mode and the memory of the
# machine.  A rehearsal reads it from the file DISKS_DETAIL names (next to
# the fixture); a system reports what its hook os_disks_detail finds, and
# the section fills in the rest from the list of the disks.  The section
# names the disks of the list (cmd_disks_detail DISK...), so the disks are
# not looked for twice.
cmd_disks_detail() {
	if [ -n "${rehearsal}" ]; then
		# Captured outputs of the real tools, replayed through the probe.
		# DISKS_CAPTURE: directories (':' between them) relative to the
		# fixture; DISKS_SNIFFS: what the signature read finds there.
		_cap=$(kv_get "${rehearsal}" DISKS_CAPTURE) || _cap=''
		if [ -n "${_cap}" ]; then
			_sniffs=$(kv_get "${rehearsal}" DISKS_SNIFFS) || _sniffs=''
			python3 -I -B "${root}/lib/diskprobe.py" --base "${rehearsal%/*}" --replay "${_cap}" \
				${_sniffs:+--sniffs "${_sniffs}"} "$(config_value OS)" "$@"
			return 0
		fi
		_file=$(kv_get "${rehearsal}" DISKS_DETAIL) || _file=''
		[ -n "${_file}" ] || { printf '{}\n'; return 0; }
		case "${_file}" in
			/*) : ;;
			*) _file="${rehearsal%/*}/${_file}" ;;
		esac
		cat "${_file}"
		return 0
	fi
	if command -v os_disks_detail >/dev/null 2>&1; then
		os_disks_detail
		return 0
	fi
	# What is on the disks named (the disks that may be written to, from
	# the verb disks), read by lib/diskprobe.py with the tools of the
	# system, only reading.  No disk named, nothing is read.
	[ $# -gt 0 ] || { printf '{}\n'; return 0; }
	for _n in "$@"; do
		disk_name_valid "${_n}" || die 2 "not the name of a disk: ${_n}"
	done
	python3 -I -B "${root}/lib/diskprobe.py" "$(config_value OS)" "$@" || printf '{}\n'
}

# cmd_image_size — the bytes the installed system takes: what the hook
# os_image_size says (the image the install command writes), else the space
# the live root uses (the install command copies it).  A rehearsal reads
# IMAGE_SIZE.  Nothing when it cannot be told.
cmd_image_size() {
	if [ -n "${rehearsal}" ]; then
		kv_get "${rehearsal}" IMAGE_SIZE || :
		return 0
	fi
	if command -v os_image_size >/dev/null 2>&1; then
		os_image_size
		return 0
	fi
	/bin/df -k / 2>/dev/null | awk 'NR == 2 && $3 ~ /^[0-9]+$/ { printf "%.0f\n", $3 * 1024 }' || :
}

# cmd_layouts — what the install command of the system can do with disks:
# the layouts, the filesystems, the modes and whether data pools are
# offered, as JSON.  The disk page and the root helper offer and accept
# nothing else.  A system without the hook os_layouts uses the built-in
# table of lib/diskplan.py ({} here).
cmd_layouts() {
	if install_capabilities; then
		return 0
	fi
	if command -v os_layouts >/dev/null 2>&1; then
		os_layouts
		return 0
	fi
	printf '{}\n'
}

# cmd_licensed_items — the path of the catalogue of the optional licensed
# software: licensed-software.json in the licences directory of the
# installer (install-into-stage.sh --licences puts it there), or the file
# LICENSED_CATALOGUE of a rehearsal.  Nothing when there is none.
cmd_licensed_items() {
	if [ -n "${rehearsal}" ]; then
		_file=$(kv_get "${rehearsal}" LICENSED_CATALOGUE) || return 0
		case "${_file}" in
			/*) printf '%s\n' "${_file}" ;;
			*) printf '%s\n' "${rehearsal%/*}/${_file}" ;;
		esac
		return 0
	fi
	if [ -f "${root}/licences/licensed-software.json" ]; then
		printf '%s\n' "${root}/licences/licensed-software.json"
	fi
}

# cmd_wifi_scan <adapter> — the Wi-Fi networks in reach, "ssid|security|
# signal" a line; a rehearsal reads WIFI_SCAN (comma separated).  A system
# scans with its hook os_wifi_scan.
cmd_wifi_scan() {
	[ $# -eq 1 ] || die 3 'wifi-scan needs the name of an adapter'
	printf '%s\n' "$1" | grep -Eq '^[a-z][a-z0-9]{0,14}$' || die 3 'not the name of an adapter'
	if [ -n "${rehearsal}" ]; then
		_v=$(kv_get "${rehearsal}" WIFI_SCAN) || return 0
		printf '%s\n' "${_v}" | tr ',' '\n'
		return 0
	fi
	if command -v os_wifi_scan >/dev/null 2>&1; then
		os_wifi_scan "$1"
	fi
}

# cmd_online_check — "yes" when the machine reaches the network now (a
# default route), "no" otherwise; a rehearsal reads ONLINE.
cmd_online_check() {
	if [ -n "${rehearsal}" ]; then
		kv_get "${rehearsal}" ONLINE || printf 'no\n'
		return 0
	fi
	if netstat -rn 2>/dev/null | awk '$1 == "default" || $1 == "0.0.0.0" { f = 1 } END { exit !f }'; then
		printf 'yes\n'
	else
		printf 'no\n'
	fi
}

# cmd_hardware — the parts of the machine as JSON {"devices": [{"class",
# "name", "driver", "firmware", "status"}]}; a rehearsal reads the file
# HARDWARE names, a system its hook os_hardware.
cmd_hardware() {
	if [ -n "${rehearsal}" ]; then
		# Captured outputs of the real tools, replayed (HARDWARE_CAPTURE, a
		# directory next to the fixture), or a finished report (HARDWARE).
		if _cap=$(kv_get "${rehearsal}" HARDWARE_CAPTURE) && [ -n "${_cap}" ]; then
			case "${_cap}" in
				/*) : ;;
				*) _cap="${rehearsal%/*}/${_cap}" ;;
			esac
			python3 -I -B "${root}/lib/hwprobe.py" --replay "${_cap}" "$(config_value OS)"
			return 0
		fi
		_file=$(kv_get "${rehearsal}" HARDWARE) || { printf '{}\n'; return 0; }
		case "${_file}" in
			/*) : ;;
			*) _file="${rehearsal%/*}/${_file}" ;;
		esac
		cat "${_file}"
		return 0
	fi
	if command -v os_hardware >/dev/null 2>&1; then
		os_hardware
		return 0
	fi
	# The tools of the system, read only (lib/hwprobe.py).
	python3 -I -B "${root}/lib/hwprobe.py" "$(config_value OS)" || printf '{}\n'
}

# cmd_locales — the UTF-8 locales of the system, one per line ("locale -a");
# a rehearsal reads LOCALES (comma separated) from the fixture.
cmd_locales() {
	if [ -n "${rehearsal}" ]; then
		_v=$(kv_get "${rehearsal}" LOCALES) || return 0
		printf '%s\n' "${_v}" | tr ',' '\n'
		return 0
	fi
	locale -a 2>/dev/null | grep -E '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$' | sort -u || :
}

cmd_network() {
	work=$(mktemp "${tmp_root}/wtfbsd-network.XXXXXX") ||
		die 3 'cannot create a temporary file'
	if [ -n "${rehearsal}" ]; then
		fixture_items INTERFACES > "${work}"
	else
		os_interfaces | while IFS= read -r _a; do
			case "${_a}" in
				''|lo|lo[0-9]*|pflog*|pfsync*|enc*|gif*|stf*|faith*|tun*|tap*|bridge*|vether*|carp*) continue ;;
			esac
			printf '%s\t%s\t0\n' "${_a}" 'network adapter'
		done > "${work}"
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
	# The install command of the template writes the disk itself.
	printf 'disk: %s is prepared by the install command\n' "$1"
}

cmd_verify_disk() {
	[ $# -eq 1 ] || die 3 'verify-disk needs the name of the disk'
	disk_name_valid "$1" || die 3 "the name '$1' is not the name of a disk"
	if [ -n "${rehearsal}" ]; then
		printf 'disk: %s is ready\n' "$1"
		return 0
	fi
	cmd_disks | grep -q "\"name\":\"$1\"" ||
		die 3 "the disk $1 is not a disk that may be written to"
	printf 'disk: %s is ready\n' "$1"
}

# rehearse_install — the rehearsal of the installation: progress lines on
# standard output, the steps on standard error, and the exit code the
# fixture asks for.
rehearse_install() {
	for _step in '10 preparing the target disk' '40 writing the system files' \
		'70 applying the settings' '90 installing the boot loader'; do
		printf 'PROGRESS %s\n' "${_step}"
		printf 'install: %s\n' "${_step#* }"
		# A site or a test may slow the rehearsal down to watch it.
		case "${INSTALLER_REHEARSAL_STEP_SECONDS:-0}" in
			0|''|*[!0-9]*) : ;;
			*) sleep "${INSTALLER_REHEARSAL_STEP_SECONDS}" ;;
		esac
	done
	_code=$(kv_get "${rehearsal}" INSTALL_EXIT) || _code=0
	case "${_code}" in
		''|*[!0-9]*) _code=0 ;;
	esac
	_once=$(kv_get "${rehearsal}" INSTALL_FAIL_ONCE) || _once=''
	if [ "${_once}" = yes ] && [ ! -f "${fail_marker}" ]; then
		: > "${fail_marker}"
		_code=3
	fi
	if [ "${_code}" -ne 0 ]; then
		printf 'ERROR the installation failed\n'
		printf 'install: the installation failed\n'
		exit "${_code}"
	fi
	printf 'PROGRESS 100 the system is installed\n'
	return 0
}

# install_capabilities — what the installed install command says it can do
# ("--capabilities"), checked and printed as one JSON object; false (and
# nothing printed) when there is no such command, it does not know the
# option, or its answer is not a usable object.  A rehearsal asks only an
# install command named by INSTALLER_INSTALL_COMMAND.
install_capabilities() {
	if [ -n "${rehearsal}" ] && [ -z "${INSTALLER_INSTALL_COMMAND:-}" ]; then
		return 1
	fi
	# Never a command found on the caller's PATH: the one a test names, or
	# the installed one in the directories of the system's own programs.
	_cap_cmd=${INSTALLER_INSTALL_COMMAND:-}
	if [ -z "${_cap_cmd}" ]; then
		_slug=$(config_value PRODUCT_SLUG) || return 1
		# The slug rule of the questions (DISTRO_SLUG): nothing else goes
		# into a path.
		printf '%s\n' "${_slug}" | grep -Eq '^[a-z][a-z0-9-]{1,31}$' || return 1
		for _d in /usr/local/sbin /usr/local/bin /usr/pkg/sbin /usr/pkg/bin \
			/opt/local/sbin /opt/local/bin /usr/sbin /usr/bin /sbin /bin; do
			if [ -f "${_d}/${_slug}-install" ] && [ -x "${_d}/${_slug}-install" ]; then
				_cap_cmd="${_d}/${_slug}-install"
				break
			fi
		done
	fi
	case "${_cap_cmd}" in
		/*) : ;;
		*) return 1 ;;
	esac
	[ -f "${_cap_cmd}" ] && [ -x "${_cap_cmd}" ] && [ ! -L "${_cap_cmd}" ] || return 1
	# Run by Python: no shell, a minimal environment, 10 seconds at most
	# (its process group killed after that), 64 KiB of answer at most.
	python3 -I -B "${root}/lib/diskplan.py" --check-capabilities "${_cap_cmd}" </dev/null 2>/dev/null
}

# install_command — the path of the install command of the template.
install_command() {
	if [ -n "${INSTALLER_INSTALL_COMMAND:-}" ]; then
		printf '%s\n' "${INSTALLER_INSTALL_COMMAND}"
		return 0
	fi
	_slug=$(config_value PRODUCT_SLUG) || return 2
	command -v "${_slug}-install" 2>/dev/null || {
		printf '%s-install\n' "${_slug}"
		return 1
	}
}

# arg_full_name_ok <text> — a full name may go on the command line: at most
# 64 characters, no colon (the separator of the account files), no line
# break and no other control character.
arg_full_name_ok() {
	[ -n "$1" ] || return 1
	[ "${#1}" -le 64 ] || return 1
	case "$1" in
		*:*) return 1 ;;
	esac
	_clean=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')
	[ "${_clean}" = "$1" ]
}

# arg_ifname_ok <name> — the name of a network adapter.
arg_ifname_ok() {
	printf '%s\n' "$1" | grep -Eq '^[a-z][a-z0-9]{0,14}$' &&
		[ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ]
}

# arg_ipv4_ok <address> is in lib/ipv4.sh, which the network section uses
# as well.

# network_arg — the value of -N for the answers, or nothing for a system
# without a network.  Fails with a reason when an answer is not well formed.
network_arg() {
	_mode=$(answers_get NETWORK_MODE) || _mode=dhcp
	case "${_mode}" in
		offline) return 0 ;;
		dhcp|static) : ;;
		*) printf 'the network mode is not known'; return 1 ;;
	esac
	_if=$(answers_get NET_IF) || _if=''
	if [ -z "${_if}" ]; then
		[ "${_mode}" = dhcp ] && return 0
		printf 'a manual address needs a network adapter'
		return 1
	fi
	arg_ifname_ok "${_if}" || { printf 'the network adapter name is not valid'; return 1; }
	if [ "${_mode}" = dhcp ]; then
		printf '%s:dhcp' "${_if}"
		return 0
	fi
	_a=$(answers_get IPV4_ADDR) || _a=''
	_m=$(answers_get IPV4_MASK) || _m=''
	_g=$(answers_get IPV4_GW) || _g=''
	arg_ipv4_ok "${_a}" || { printf 'the address is not an IPv4 address'; return 1; }
	arg_ipv4_ok "${_m}" || { printf 'the netmask is not an IPv4 netmask'; return 1; }
	if [ -n "${_g}" ]; then
		arg_ipv4_ok "${_g}" || { printf 'the gateway is not an IPv4 address'; return 1; }
	fi
	printf '%s:%s/%s:%s' "${_if}" "${_a}" "${_m}" "${_g}"
}

# run_install_command — build the arguments of the install command from the
# answers, run it and pass its progress lines on.  The hash file is named,
# never read: the password itself never reaches this script.
run_install_command() {
	_cmd=$(install_command) || {
		printf 'ERROR the install command %s is not installed\n' "${_cmd}"
		exit 3
	}
	_disk=$(answers_get DISK) || { printf 'ERROR no disk was chosen\n'; exit 2; }
	disk_name_valid "${_disk}" || { printf 'ERROR the disk name is not valid\n'; exit 2; }
	_user=$(answers_get USER_NAME) || { printf 'ERROR no user name was given\n'; exit 2; }
	_auth=$(answers_get USER_AUTH) || _auth=password
	if [ "${_auth}" != password ]; then
		printf 'ERROR the install command needs a password for %s\n' "${_user}"
		exit 2
	fi
	_hash=$(answers_get USER_HASHFILE) || {
		printf 'ERROR no password hash file was given\n'
		exit 2
	}
	[ -s "${_hash}" ] || { printf 'ERROR the password hash file is empty\n'; exit 2; }
	# The disk plan replaces the disk when there is one (-p PLANFILE).
	if _plan=$(answers_get PLAN_FILE) && [ -n "${_plan}" ]; then
		[ -f "${_plan}" ] || { printf 'ERROR the plan file is not there\n'; exit 2; }
		set -- "${_cmd}" -p "${_plan}" -u "${_user}"
	else
		set -- "${_cmd}" -d "${_disk}" -u "${_user}"
	fi
	# The licences the user accepted (-l ACCEPTFILE); the command installs
	# those optional items and no other.
	if _acc=$(answers_get ACCEPT_FILE) && [ -n "${_acc}" ]; then
		[ -s "${_acc}" ] || { printf 'ERROR the file of the accepted licences is empty\n'; exit 2; }
		set -- "$@" -l "${_acc}"
	fi
	if _pass=$(answers_get PASSPHRASE_FILE) && [ -n "${_pass}" ]; then
		[ -s "${_pass}" ] || { printf 'ERROR the passphrase file is empty\n'; exit 2; }
		set -- "$@" -E "${_pass}"
	fi
	if _key=$(answers_get SSH_KEYFILE) && [ -n "${_key}" ]; then
		set -- "$@" -k "${_key}"
	fi
	set -- "$@" -H "${_hash}"
	if _v=$(answers_get HOSTNAME) && [ -n "${_v}" ]; then
		set -- "$@" -n "${_v}"
	fi
	if _v=$(answers_get TIMEZONE) && [ -n "${_v}" ]; then
		set -- "$@" -z "${_v}"
	fi
	if _v=$(answers_get KEYMAP) && [ -n "${_v}" ]; then
		set -- "$@" -K "${_v}"
	fi
	if _v=$(answers_get LOCALE) && [ -n "${_v}" ]; then
		printf '%s\n' "${_v}" | grep -Eq '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$' ||
			{ printf 'ERROR the locale is not valid\n'; exit 2; }
		set -- "$@" -L "${_v}"
	fi
	if _v=$(answers_get CLOCK) && [ -n "${_v}" ]; then
		case "${_v}" in
			utc|local) set -- "$@" -Z "${_v}" ;;
			*) printf 'ERROR the clock is not utc or local\n'; exit 2 ;;
		esac
	fi
	if _v=$(answers_get USER_FULLNAME) && [ -n "${_v}" ]; then
		arg_full_name_ok "${_v}" || {
			printf 'ERROR the full name may not hold a colon or a control character\n'
			exit 2
		}
		set -- "$@" -c "${_v}"
	fi
	if [ "$(answers_get PRIVILEGE_PASSWORDLESS || :)" = yes ]; then
		set -- "$@" -P
	fi
	if [ -n "$(answers_get NET_IPV4_LIST || :)$(answers_get NET_IPV6_LIST || :)$(answers_get DNS_SERVERS || :)$(answers_get WIFI_FILE || :)$(answers_get UPDATE_AFTER || :)" ]; then
		# Every adapter, the resolvers, Wi-Fi and the update, checked and
		# built by lib/netplan.py, one option a line.
		_net=$(python3 -I -B "${root}/lib/netplan.py" argv "${INSTALLER_ANSWERS}" 2>&1) ||
			{ printf 'ERROR %s\n' "$(printf '%s' "${_net}" | tr '\n' ';')"; exit 2; }
		_nl='
'
		_old_ifs=${IFS}
		IFS=${_nl}
		# shellcheck disable=SC2086
		set -- "$@" ${_net}
		IFS=${_old_ifs}
	else
		_v=$(network_arg) || { printf 'ERROR %s\n' "${_v}"; exit 2; }
		if [ -n "${_v}" ]; then
			set -- "$@" -N "${_v}"
		fi
	fi
	case "$(answers_get ROOT_MODE || printf 'locked')" in
		password)
			_rh=$(answers_get ROOT_HASHFILE) || { printf 'ERROR no root hash file\n'; exit 2; }
			set -- "$@" -r "${_rh}"
			;;
		*) set -- "$@" -r locked ;;
	esac
	if [ "$(answers_get AUTOLOGIN || :)" = yes ]; then
		set -- "$@" -A
	fi
	set -- "$@" -y --progress
	printf 'install: running %s\n' "$*" >&2
	# The file of the error marker belongs to the cleanup of the run, so
	# that it is gone when the run ends in any way.
	_errfile=$(mktemp "${tmp_root}/wtfbsd-install-err.XXXXXX") ||
		die 3 'cannot create a temporary file'
	install_err=${_errfile}
	# The install command writes to a pipe of the run and the shell reads
	# the pipe, so that the lines of the command are passed on as they
	# come.  The command runs in the background: a shell that waits for a
	# command in the foreground runs its trap only when that command
	# ends, so an interrupted run would wait for the installation to end
	# before it stopped, and a run that was killed would leave the files
	# of the run behind.
	#
	# The pipe is named after the file of the error marker, whose name
	# is unique.  It is a file of the run as well, and the cleanup
	# removes it.
	install_pipe="${_errfile}.pipe"
	mkfifo -m 600 "${install_pipe}" ||
		die 3 'cannot create the pipe of the install command'
	# The command gets a process group of its own, so that an interrupted
	# run stops the command and every process it started (set -m is not
	# there without a terminal in every sh).  lib/pgroup.py makes the
	# group and becomes the command: the process number stays the same.
	python3 -I -B "${root}/lib/pgroup.py" "$@" < /dev/null > "${install_pipe}" &
	install_pid=$!
	while IFS= read -r _line; do
		printf '%s\n' "${_line}"
		case "${_line}" in
			ERROR\ *) : > "${_errfile}.seen" ;;
		esac
	done < "${install_pipe}"
	_c=0
	wait "${install_pid}" || _c=$?
	install_pid=''
	case "${_c}" in ''|*[!0-9]*) _c=4 ;; esac
	_seen=no
	[ ! -f "${_errfile}.seen" ] || _seen=yes
	if [ "${_c}" -ne 0 ]; then
		[ "${_seen}" = yes ] ||
			printf 'ERROR the install command failed with exit code %s\n' "${_c}"
		exit "${_c}"
	fi
	if [ -n "${INSTALLER_STATE_DIR:-}" ]; then
		: > "${INSTALLER_STATE_DIR}/install-done" 2>/dev/null || :
	fi
	return 0
}

cmd_apply_install() {
	if [ -n "${rehearsal}" ]; then
		rehearse_install
		return 0
	fi
	run_install_command
}

cmd_verify_install() {
	if [ -n "${rehearsal}" ]; then
		printf 'install: the system is installed\n'
		return 0
	fi
	# The install command exits 0 only when the disk is bootable and the
	# first boot configuration is written; apply leaves a mark when it did.
	if [ -n "${INSTALLER_STATE_DIR:-}" ] &&
		[ -f "${INSTALLER_STATE_DIR}/install-done" ]; then
		printf 'install: the system is installed\n'
		return 0
	fi
	die 4 'the install command did not report a finished installation'
}

cmd_target_root() {
	if [ -n "${rehearsal}" ]; then
		kv_get "${rehearsal}" TARGET_ROOT || :
	fi
	return 0
}

# cmd_keymaps — the keyboard layouts.  A rehearsal reads KEYMAPS from the
# fixture; without it the section falls back to its own list.
# cmd_keymaps — the keymaps: in a rehearsal the KEYMAPS of the fixture, else
# the list of the system (os_keymaps, which reads the keymaps of the system
# and falls back to the full list of that system it knows).
cmd_keymaps() {
	if [ -n "${rehearsal}" ] && _v=$(kv_get "${rehearsal}" KEYMAPS); then
		# shellcheck disable=SC2046
		keymap_rows $(printf '%s' "${_v}" | tr ',' ' ')
		return 0
	fi
	os_keymaps
}

# cmd_timezones — the time zones: in a rehearsal the ZONES of the fixture
# or every zone of the installer's table, else the zone table of the
# system (zone_rows).
cmd_timezones() {
	if [ -n "${rehearsal}" ]; then
		if _v=$(kv_get "${rehearsal}" ZONES); then
			for _z in $(printf '%s' "${_v}" | tr ',' ' '); do
				printf '%s\t%s\n' "${_z}" "${_z}"
			done
			return 0
		fi
		zone_rows "${root}/lib/zone1970.tab"
		return 0
	fi
	zone_rows
}

# adapter_main <operation> [arguments...]
adapter_main() {
	_op=${1:-}
	if [ $# -ge 1 ]; then
		shift
	fi
	rehearsal=$(rehearsal_file) || rehearsal=''
	# The files of the run are gone when the run ends, and a signal
	# ends the run at once: the code of the signal is the code of the
	# run (129 for HUP, 130 for INT, 143 for TERM).
	trap 'cleanup' EXIT
	trap 'signal_exit 129' HUP
	trap 'signal_exit 130' INT
	trap 'signal_exit 143' TERM
	case "${_op}" in
		apply-install) setup_fail_marker ;;
	esac
	case "${_op}" in
		disks) cmd_disks "$@" ;;
		disks-detail) cmd_disks_detail "$@" ;;
		layouts) cmd_layouts "$@" ;;
		image-size) cmd_image_size "$@" ;;
		locales) cmd_locales "$@" ;;
		hardware) cmd_hardware "$@" ;;
		wifi-scan) cmd_wifi_scan "$@" ;;
		online-check) cmd_online_check "$@" ;;
		licensed-items) cmd_licensed_items "$@" ;;
		network) cmd_network "$@" ;;
		apply-disk) cmd_apply_disk "$@" ;;
		verify-disk) cmd_verify_disk "$@" ;;
		apply-install) cmd_apply_install "$@" ;;
		verify-install) cmd_verify_install "$@" ;;
		target-root) cmd_target_root "$@" ;;
		keymaps) cmd_keymaps "$@" ;;
		timezones) cmd_timezones "$@" ;;
		hash-scheme) os_hash_scheme ;;
		*) die 3 "unknown adapter operation '${_op}'" ;;
	esac
}

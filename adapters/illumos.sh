#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The illumos adapter.  Tested against outputs captured on OpenIndiana
# 2026.10 (tests/fixtures/captures/illumos, hw-captures/illumos,
# fixtures/illumos): the disks, the hardware, the keymaps, the hash scheme
# and where the zone table lives (the listing of the zoneinfo directory).
# NOT capture-tested yet, written after the documented formats: /etc/mnttab
# (which disks the running system needs), dladm scan-wifi, and the columns
# of tab/zone_sun.tab.
#
#   disks       diskinfo -Hp (cXtYdZ names, sizes in bytes); the report of
#               the disks: lib/diskprobe.py (diskinfo, iostat -En, zpool)
#   excluded    the disk of the live medium (/.cdrom) and the disks of the
#               pool the root is in (/etc/mnttab, zpool status)
#   network     dladm show-phys -p -o link; Wi-Fi: dladm scan-wifi
#   keymaps     /usr/share/lib/keytables/type_6/kbd_layouts (never kbd -s:
#               without a terminal it asks again forever)
#   timezones   the zone table under /usr/share/lib/zoneinfo
#   hash        CRYPT_DEFAULT of /etc/security/policy.conf (6: sha512)
#   layouts     what the install command says (--capabilities, see
#               lib/adapter.sh); without it the same, from os_layouts
#   hardware    lib/hwprobe.py (prtconf -D, scanpci)

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

os_disk_rows() {
	[ -x /usr/sbin/diskinfo ] || die 3 'reading the disks needs diskinfo'
	/usr/sbin/diskinfo -Hp 2>/dev/null | python3 -I "${root}/lib/illumos.py" disks
}

os_excluded_disks() {
	# The medium and the pool of the root (lib/illumos.py excluded), or
	# cannot_tell when they cannot be told: nothing is then offered (a
	# rehearsal follows the rule of cannot_tell).  A rehearsal on captures
	# reads the zpool status of the capture.
	_status='' _zrc=1
	if [ -n "${rehearsal}" ] && _cap=$(kv_get "${rehearsal}" DISKS_CAPTURE) && [ -n "${_cap}" ]; then
		_cap=${_cap%%:*}
		case "${_cap}" in
			/*) : ;;
			*) _cap="${rehearsal%/*}/${_cap}" ;;
		esac
		if [ -f "${_cap}/zpool_status.out" ]; then
			_status=$(cat "${_cap}/zpool_status.out")
			_zrc=$(cat "${_cap}/zpool_status.rc" 2>/dev/null) || _zrc=1
		fi
	elif [ -x /usr/sbin/zpool ]; then
		_zrc=0
		_status=$(/usr/sbin/zpool status 2>/dev/null) || _zrc=$?
	fi
	case "${_zrc}" in
		''|*[!0-9]*) _zrc=1 ;;
	esac
	_why=$(mktemp "${tmp_root}/wtfbsd-excluded.XXXXXX") || cannot_tell 'cannot create a temporary file'
	_out=$(printf '%s\n' "${_status}" |
		python3 -I "${root}/lib/illumos.py" excluded "${INSTALLER_MNTTAB:-/etc/mnttab}" "${_zrc}" \
		2>"${_why}") || {
		_reason=$(head -n 1 "${_why}")
		rm -f "${_why}"
		cannot_tell "${_reason:-lib/illumos.py excluded failed}"
	}
	rm -f "${_why}"
	printf '%s\n' "${_out}" | tr '\n' ' '
}

os_interfaces() {
	[ -x /usr/sbin/dladm ] || die 3 'reading the network adapters needs dladm'
	/usr/sbin/dladm show-phys -p -o link 2>/dev/null | python3 -I "${root}/lib/illumos.py" links
}

# The keymaps of illumos (the names of kbd_layouts of OpenIndiana 2026.10,
# tests/fixtures/illumos/kbd_layouts), for a system whose table cannot be
# read.
KEYMAPS_KNOWN="Albanian Arabic Belarusian Belgian Brazilian Bulgarian
Canadian-Bilingual Croatian Czech Danish Dutch Dvorak Estonian Finnish
French French-Canadian Hungarian German Greek Icelandic Italian
Japanese-type6 Japanese Korean Latin-American Lithuanian Latvian
Macedonian Malta_UK Malta_US Norwegian Polish Portuguese Romanian
Russian Serbia-And-Montenegro Slovak Slovenian Spanish Swedish
Swiss-French Swiss-German Traditional-Chinese TurkishF TurkishQ
UK-English US-English"

os_keymaps() {
	_layouts=/usr/share/lib/keytables/type_6/kbd_layouts
	if [ -f "${_layouts}" ]; then
		python3 -I "${root}/lib/illumos.py" layouts < "${_layouts}" | while IFS= read -r _k; do
			printf '%s\t%s\n' "${_k}" "${_k}"
		done
		return 0
	fi
	keymaps_known "${_layouts}" ${KEYMAPS_KNOWN}
}

# os_layouts — the same as "<slug>-install --capabilities" of the illumos
# template (tests/fixtures/illumos/capabilities.json, a copy of its answer;
# case 91 holds the two to each other and to lib/diskplan.py), for a system
# whose install command does not answer.
os_layouts() {
	cat <<'JSON'
{
 "modes": [
  "erase"
 ],
 "data_pools": false,
 "boot": [
  "uefi",
  "bios"
 ],
 "encryption": "",
 "not_offered": "not offered on illumos yet",
 "filesystems": [
  [
   "zfs",
   "ZFS"
  ]
 ],
 "layouts": [
  {
   "ident": "single",
   "title": "Single disk",
   "min_disks": 1,
   "max_disks": 1,
   "even": false,
   "note": "",
   "encrypted": false
  },
  {
   "ident": "stripe",
   "title": "Stripe",
   "min_disks": 2,
   "max_disks": 64,
   "even": false,
   "note": "all the space, no redundancy",
   "encrypted": false
  },
  {
   "ident": "mirror",
   "title": "Mirror",
   "min_disks": 2,
   "max_disks": 64,
   "even": false,
   "note": "",
   "encrypted": false
  },
  {
   "ident": "raid10",
   "title": "RAID 10",
   "min_disks": 4,
   "max_disks": 64,
   "even": true,
   "note": "mirrors, striped",
   "encrypted": false
  },
  {
   "ident": "raidz1",
   "title": "RAID-Z1",
   "min_disks": 3,
   "max_disks": 64,
   "even": false,
   "note": "",
   "encrypted": false
  },
  {
   "ident": "raidz2",
   "title": "RAID-Z2",
   "min_disks": 4,
   "max_disks": 64,
   "even": false,
   "note": "",
   "encrypted": false
  },
  {
   "ident": "raidz3",
   "title": "RAID-Z3",
   "min_disks": 5,
   "max_disks": 64,
   "even": false,
   "note": "",
   "encrypted": false
  }
 ],
 "home_encryption": "ZFS native",
 "usages": [
  "together"
 ],
 "swap_encryption": false
}
JSON
}

os_zoneinfo_dir() {
	printf '/usr/share/lib/zoneinfo\n'
}

os_wifi_scan() {
	[ -x /usr/sbin/dladm ] || return 0
	/usr/sbin/dladm scan-wifi -p -o essid,secmode,strength "$1" 2>/dev/null |
		python3 -I "${root}/lib/illumos.py" wifi || :
}

os_hash_scheme() {
	python3 -I "${root}/lib/illumos.py" hash < "${INSTALLER_POLICY_CONF:-/etc/security/policy.conf}" 2>/dev/null ||
		printf 'sha512\n'
}

adapter_main "$@"

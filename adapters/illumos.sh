#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The illumos adapter.  UNPROVEN: written against the documented formats of
# the illumos tools (lib/illumos.py), without an illumos machine.  Until
# captured outputs prove it, it answers in a rehearsal only; on a real
# machine it reports the gap and exits 3, so an unfinished system is never
# mistaken for a working one.
#
#   disks       diskinfo -Hp (cXtYdZ names, sizes in bytes)
#   network     dladm show-phys -p -o link
#   keymaps     /usr/share/lib/keytables/type_6/kbd_layouts (the layouts
#               kbd -s offers)
#   timezones   the zone table of zoneinfo
#   hash        sha512 ($6$, crypt_sha512 of crypt.conf)
#   layouts     ZFS: single, mirror, raidz1, raidz2; Erase and install only
#   hardware    not read yet (prtconf -v, prtdiag): "not available"

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"
. "${root}/lib/adapter.sh"

if ! rehearsal_file >/dev/null 2>&1; then
	die 3 'adapter not implemented for illumos: written against the documented formats, it runs in a rehearsal only until outputs of a real illumos machine prove it'
fi

os_disk_rows() {
	[ -x /usr/sbin/diskinfo ] || die 3 'reading the disks needs diskinfo'
	/usr/sbin/diskinfo -Hp 2>/dev/null | python3 -I "${root}/lib/illumos.py" disks
}

os_excluded_disks() {
	# The pool the live system runs from (rpool on the media).
	_dev=$(mounted_device /) || _dev=''
	[ -n "${_dev}" ] || return 0
	device_disk_prefix "${_dev}" "$1" | tr '\n' ' ' || :
}

os_interfaces() {
	[ -x /usr/sbin/dladm ] || die 3 'reading the network adapters needs dladm'
	/usr/sbin/dladm show-phys -p -o link 2>/dev/null | python3 -I "${root}/lib/illumos.py" links
}

os_keymaps() {
	_layouts=/usr/share/lib/keytables/type_6/kbd_layouts
	if [ -f "${_layouts}" ]; then
		python3 -I "${root}/lib/illumos.py" layouts < "${_layouts}" | while IFS= read -r _k; do
			printf '%s\t%s\n' "${_k}" "${_k}"
		done
		return 0
	fi
	keymap_rows US-English UK-English German French Spanish Italian Swedish Japanese
}

os_layouts() {
	cat <<'JSON'
{"modes": ["erase"], "data_pools": false, "not_offered": "not offered on illumos yet",
 "filesystems": [["zfs", "ZFS"]],
 "layouts": [
  {"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1},
  {"ident": "mirror", "title": "Mirror", "min_disks": 2},
  {"ident": "raidz1", "title": "RAID-Z1", "min_disks": 3},
  {"ident": "raidz2", "title": "RAID-Z2", "min_disks": 4}]}
JSON
}

os_hardware() {
	printf '{"devices": [], "unavailable": ["the hardware of illumos (prtconf -v, prtdiag): not read yet"]}\n'
}

os_hash_scheme() {
	printf 'sha512\n'
}

adapter_main "$@"

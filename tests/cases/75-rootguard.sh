#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Every override of the environment is ignored for root, one by one: the
# guard removes each of them, and the scripts of the installer, run as root
# with each of them set to a hostile value, behave as if it were not set.
#
# "As root" is an id(1) on PATH that says 0 (lib/rootguard.sh), and for the
# root helper WTFBSD_TEST_AS_ROOT=yes (it reads only /usr/bin/id).

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-rootguard.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"
evil="${tmp}/evil"
fake="${tmp}/fake"
mkdir -p "${evil}/sections.d" "${evil}/zoneinfo" "${evil}/keymaps" "${fake}"
printf '#!/bin/sh\necho 0\n' > "${fake}/id"
chmod +x "${fake}/id"
: > "${evil}/marks"

# The list of the guard, read from the guard itself.
vars=$(sed -n '/^if installer_is_root; then/,/^fi/p' "${root}/lib/rootguard.sh" |
	tr ' \t\\' '\n\n\n' | grep -E '^(INSTALLER_[A-Z_]+|BSDDIALOG)$' | sort -u)
# The overrides that must never reach root, fixed here and not read from
# the guard, so that a name dropped from the guard is noticed.
overrides='INSTALLER_ROOT INSTALLER_LIBEXEC INSTALLER_CONF INSTALLER_ADAPTER_FIXTURE
	INSTALLER_INSTALL_COMMAND INSTALLER_REBOOT_COMMAND INSTALLER_ZONEINFO
	INSTALLER_KEYMAP_DIR INSTALLER_DMESG_BOOT INSTALLER_REHEARSAL_STEP_SECONDS
	INSTALLER_MEDIA_MOUNT BSDDIALOG'
for want in ${overrides}; do
	check_contains "the guard lists ${want}" "${want}" "${vars}"
done

# Directly: the guard, sourced as root, leaves none of them.
for var in ${overrides}; do
	left=$(env PATH="${fake}:${PATH}" "${var}=hostile" sh -c \
		'. "$1/lib/rootguard.sh"; env' sh "${root}" | grep -c "^${var}=" || true)
	check "as root the guard removes ${var}" 0 "${left}"
	left=$(env "${var}=kept" sh -c '. "$1/lib/rootguard.sh"; env' sh "${root}" |
		grep -c "^${var}=" || true)
	check "for a user the guard keeps ${var}" 1 "${left}"
done

# By its effect: every script of the installer, as root, with one variable
# set to a hostile value.
asroot() { # asroot VAR=value <command...>
	env PATH="${fake}:${stubs}:${PATH}" STUB_DISKS='ada0 ada1' STUB_INTERFACES=em0 \
		STUB_DISK_INFO="${tmp}/disk-info" STUB_MOUNTS="${tmp}/mounts" "$@" 2>&1 < /dev/null || :
}
printf 'ada0\tSamsung SSD 860\t500107862016\nada1\tUSB stick\t15000000000\n' > "${tmp}/disk-info"
printf '/dev/ada9p3 / ufs rw 0 0\n/dev/ada1p1 /mnt ufs ro 0 0\n' > "${tmp}/mounts"

# INSTALLER_ROOT and INSTALLER_LIBEXEC: sections of the caller.
mkdir -p "${evil}/bin"
printf '#!/bin/sh\necho section >> "%s/marks"\necho "{\\"disks\\":[{\\"name\\":\\"evil0\\"}]}"\n' \
	"${evil}" > "${evil}/sections.d/disk.sh"
chmod +x "${evil}/sections.d/disk.sh"
cp "${backend}" "${evil}/bin/installer-backend"
out=$(asroot INSTALLER_ROOT="${evil}" "${backend}" disk probe)
check_absent "INSTALLER_ROOT is ignored for root" "evil0" "${out}"
out=$(asroot INSTALLER_LIBEXEC="${evil}/sections.d" "${backend}" disk probe)
check_absent "INSTALLER_LIBEXEC is ignored for root" "evil0" "${out}"

# INSTALLER_CONF: the configuration of the caller.
printf 'PRODUCT_NAME=EvilBSD\nPRODUCT_SLUG=evil\nOS=freebsd\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' \
	> "${evil}/installer.conf"
out=$(asroot INSTALLER_CONF="${evil}/installer.conf" "${backend}" welcome probe)
check_contains "INSTALLER_CONF is ignored for root" '"product":"ExampleBSD"' "${out}"

# INSTALLER_ADAPTER_FIXTURE: the hardware of the caller.
printf 'DISKS=evil0|Evil|1\nINTERFACES=evil0\n' > "${evil}/fixture.conf"
out=$(asroot INSTALLER_ADAPTER_FIXTURE="${evil}/fixture.conf" "${backend}" disk probe)
check_absent "INSTALLER_ADAPTER_FIXTURE is ignored for root" "evil0" "${out}"

# INSTALLER_INSTALL_COMMAND: the install command of the caller.
printf '#!/bin/sh\necho command >> "%s/marks"\necho "PROGRESS 100 Done"\n' "${evil}" > "${evil}/command"
chmod +x "${evil}/command"
printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${tmp}/s/user.hash"
printf 'DISK=ada0\nUSER_NAME=tester\nUSER_AUTH=password\nUSER_HASHFILE=%s/s/user.hash\n' "${tmp}" \
	> "${tmp}/answers"
: > "${evil}/marks"
out=$(asroot INSTALLER_ANSWERS="${tmp}/answers" INSTALLER_INSTALL_COMMAND="${evil}/command" \
	"${backend}" install apply)
check "INSTALLER_INSTALL_COMMAND is ignored for root" "" "$(cat "${evil}/marks")"
check_contains "root runs the install command of the product from PATH" \
	"tests/stubs/examplebsd-install -d ada0" "${out}"

# INSTALLER_REBOOT_COMMAND: the helper reboots with /sbin/shutdown only.
: > "${evil}/marks"
out=$(asroot WTFBSD_TEST_AS_ROOT=yes INSTALLER_REBOOT_COMMAND="${evil}/command" \
	"${root}/bin/installer-apply" --reboot)
check "INSTALLER_REBOOT_COMMAND is ignored for root" "" "$(cat "${evil}/marks")"

# INSTALLER_ZONEINFO: the zones of the caller.
printf 'XX\t+0000+00000\tEvil/Zone\n' > "${evil}/zoneinfo/zone1970.tab"
out=$(asroot INSTALLER_ZONEINFO="${evil}/zoneinfo" "${backend}" timezone probe)
check_absent "INSTALLER_ZONEINFO is ignored for root" "Evil/Zone" "${out}"

# INSTALLER_KEYMAP_DIR: the keymaps of the caller.
: > "${evil}/keymaps/evilmap.kbd"
out=$(asroot INSTALLER_KEYMAP_DIR="${evil}/keymaps" "${backend}" keyboard probe)
check_absent "INSTALLER_KEYMAP_DIR is ignored for root" "evilmap" "${out}"

# INSTALLER_DMESG_BOOT: the kernel messages of the caller (NetBSD).
printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=netbsd\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' \
	> "${tmp}/netbsd.conf"
printf 'wd0: <Evil Model>\n' > "${evil}/dmesg.boot"
# The configuration of the system itself is the one root reads: a copy of
# the tree with the NetBSD configuration stands for it.
tree="${tmp}/tree"
mkdir -p "${tree}"
cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" "${tree}/"
cp "${tmp}/netbsd.conf" "${tree}/installer.conf"
out=$(asroot STUB_HW_DISKNAMES=wd0 INSTALLER_DMESG_BOOT="${evil}/dmesg.boot" \
	"${tree}/bin/installer-backend" disk probe)
check_absent "INSTALLER_DMESG_BOOT is ignored for root" "Evil Model" "${out}"

# INSTALLER_REHEARSAL_STEP_SECONDS: no rehearsal and no wait for root.
started=$(date +%s)
asroot INSTALLER_REHEARSAL_STEP_SECONDS=30 INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" install apply > /dev/null
check "INSTALLER_REHEARSAL_STEP_SECONDS is ignored for root" yes \
	"$([ $(( $(date +%s) - started )) -lt 10 ] && echo yes || echo no)"

# INSTALLER_MEDIA_MOUNT: the media on /mnt stays out of the list.
out=$(asroot INSTALLER_MEDIA_MOUNT=/nonexistent "${backend}" disk probe)
check_absent "INSTALLER_MEDIA_MOUNT is ignored for root (the media stays out)" '"ada1"' "${out}"
check_contains "the other disk is offered" '"ada0"' "${out}"

# BSDDIALOG: the dialog tool of the caller.
: > "${evil}/marks"
asroot BSDDIALOG="${evil}/command" "${root}/bin/installer-tui" > /dev/null
check "BSDDIALOG is ignored for root" "" "$(cat "${evil}/marks")"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A shell function of the shared libraries (lib/*.sh) is defined there
# only: an adapter, a section or a front end that defines it again shadows
# the shared one, and the two drift apart.  The checks of the network
# section and of the adapter are the same function.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

# defined <file> — the names of the functions a file defines.
defined() {
	sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' "$1"
}

# sources <file> — the libraries a file sources, and the libraries those
# source in turn.
sources() {
	_direct=$(sed -n 's|^[[:space:]]*\. "[^"]*/\(lib/[a-z]*\.sh\)"$|\1|p' "$1")
	for _lib in ${_direct}; do
		printf '%s\n' "${_lib}"
		[ -f "${_lib}" ] && sed -n 's|^[[:space:]]*\. "[^"]*/\(lib/[a-z]*\.sh\)"$|\1|p' "${_lib}"
	done | sort -u
}

# The overrides that are meant: the text front end prints its own name in
# its messages (bin/installer-tui, die).
meant=' die(lib/backend.sh,bin/installer-tui) '

twice=''
for lib in lib/*.sh; do
	for name in $(defined "${lib}"); do
		for other in lib/*.sh adapters/*.sh sections.d/*.sh bin/installer-*; do
			[ "${other}" != "${lib}" ] || continue
			[ -f "${other}" ] || continue
			# Only a file that sources the library shadows its function.
			sources "${other}" | grep -qx "${lib}" || continue
			if defined "${other}" | grep -qx "${name}"; then
				case "${meant}" in
					*" ${name}(${lib},${other}) "*) continue ;;
				esac
				twice="${twice} ${name}(${lib},${other})"
			fi
		done
	done
done
check "no function of lib/*.sh is defined a second time" "" "${twice}"

# The checks of an IPv4 address: one function, used by both.
check "the IPv4 check is defined once, in lib/ipv4.sh" "lib/ipv4.sh" \
	"$(grep -lE '^arg_ipv4_ok\(\)' lib/*.sh adapters/*.sh sections.d/*.sh | tr '\n' ' ' | sed 's/ $//')"
check "the network section has no IPv4 check of its own" "" \
	"$(grep -nE '^[a-z_]*ipv4[a-z_]*\(\)' sections.d/network.sh || true)"
check_contains "the network section checks the answers with the shared function" \
	'arg_ipv4_ok "$(answers_get IPV4_ADDR)"' "$(cat sections.d/network.sh)"

# The disk of a device: the FreeBSD adapter uses the shared function.
check "the FreeBSD adapter has no disk-of-a-device function of its own" "" \
	"$(grep -nE '^device_disk[a-z_]*\(\)' adapters/freebsd.sh || true)"
check_contains "the FreeBSD adapter uses device_disk_prefix" "device_disk_prefix" \
	"$(cat adapters/freebsd.sh)"

# The section refuses what the adapter refuses: an address with a stray
# character, a number above 255, too few or too many parts.  (A value of the
# answers is one line: a second line is an answer of its own.)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-onedef.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
for bad in '192.0.2.1 ' '192.0.2.256' '192.0.2' '+192.0.2.1' '192.0.2.1.5'; do
	{
		printf 'NETWORK_MODE=static\nNET_IF=em0\n'
		printf 'IPV4_ADDR=%s\n' "${bad}"
		printf 'IPV4_MASK=255.255.255.0\n'
	} > "${tmp}/answers"
	rc=0
	INSTALLER_ANSWERS="${tmp}/answers" "${root}/bin/installer-backend" network validate \
		> /dev/null 2>&1 || rc=$?
	check "the network section refuses the address '${bad}'" yes \
		"$([ "${rc}" -ne 0 ] && echo yes || echo no)"
done
printf 'NETWORK_MODE=static\nNET_IF=em0\nIPV4_ADDR=192.0.2.10\nIPV4_MASK=255.255.255.0\nIPV4_GW=192.0.2.1\n' \
	> "${tmp}/answers"
rc=0
INSTALLER_ANSWERS="${tmp}/answers" "${root}/bin/installer-backend" network validate \
	> /dev/null 2>&1 || rc=$?
check_rc "the network section accepts a good address" 0 "${rc}"

finish

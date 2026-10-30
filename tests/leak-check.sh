#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# leak-check: look for the shapes that do not belong in a public template.
#
# The file names are given as arguments.  Every violation is printed on
# standard output and the exit code is 1 when there was one.
#
# The check looks for shapes and never for the name of an organisation: an
# address that is not a documentation address, an email address that is not
# at example.org or example.com, a name in an internal domain, the header of
# a private key, a token of a well known service, a name of an API key and
# a path of a home directory.  A site that has names of its own keeps them
# in a list outside the repository and names that list in WTFBSD_DENYLIST.

set -eu

# The shapes.  They are built from fragments so that this file does not
# carry the shapes it looks for.
pat_ipv4='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
pat_ipv6='([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{1,4})*'
pat_mail='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
pat_tld='\.(lan|corp|internal|local|lab)([^A-Za-z0-9_]|$)'
pat_key=$(printf 'BE%s %sPRIVATE KEY' 'GIN' '.*')
pat_ssh=$(printf 'ssh-(ed25%s|r%s) AAAA' '519' 'sa')
pat_ghp=$(printf 'gh%s_' 'p')
pat_gho=$(printf 'gh%s_' 'o')
pat_ghpat=$(printf 'github_p%s_' 'at')
pat_akia='AKIA[0-9A-Z]{16}'
pat_xox='xox[abp]-'
pat_sk='sk-[A-Za-z0-9]{20,}'
pat_api=$(printf 'api%s|%s_key|base%s|%s' \
	"$(printf 'K%s' 'ey')" "$(printf 'a%s' 'pi')" \
	"$(printf 'U%s' 'RL')" "$(printf 'B%s' 'earer')")
pat_home=$(printf '/ho%s/' 'me')

violations=0

report() { # report <file> <what> <found>
	printf 'leak-check: %s: %s: %s\n' "$1" "$2" "$3"
	violations=$((violations + 1))
}

# address_ok <address> — the addresses a public template may carry: the
# loopback address, the addresses of the documentation ranges and the
# documentation address of the IPv6 range.
address_ok() {
	case "$1" in
		127.0.0.1) return 0 ;;
		192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;
		::1|::) return 0 ;;
		2001:db8:*) return 0 ;;
	esac
	return 1
}

check_file() { # check_file <file>
	file=$1
	[ -f "${file}" ] || return 0
	for found in $(grep -aoE "${pat_ipv4}" "${file}" 2>/dev/null || true); do
		address_ok "${found}" || report "${file}" "an address" "${found}"
	done
	for found in $(grep -aoE "${pat_ipv6}" "${file}" 2>/dev/null || true); do
		address_ok "${found}" || report "${file}" "an address" "${found}"
	done
	for found in $(grep -aoE "${pat_mail}" "${file}" 2>/dev/null || true); do
		case "${found}" in
			*@example.org|*@example.com) : ;;
			*) report "${file}" "an email address" "${found}" ;;
		esac
	done
	for found in $(grep -aoE "${pat_tld}" "${file}" 2>/dev/null || true); do
		report "${file}" "a name in an internal domain" "${found}"
	done
	for pattern in "${pat_key}" "${pat_ssh}" "${pat_ghp}" "${pat_gho}" \
		"${pat_ghpat}" "${pat_akia}" "${pat_xox}" "${pat_sk}" "${pat_api}" \
		"${pat_home}"; do
		if grep -aqE -- "${pattern}" "${file}" 2>/dev/null; then
			report "${file}" "a secret, a token or a home path" "${pattern}"
		fi
	done
}

check_denylist() { # check_denylist <file> — the private list, if there is one
	[ -n "${WTFBSD_DENYLIST:-}" ] || return 0
	[ -r "${WTFBSD_DENYLIST}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
			''|\#*) continue ;;
		esac
		for file in "$@"; do
			[ -f "${file}" ] || continue
			if grep -aqiE -- "${line}" "${file}" 2>/dev/null; then
				report "${file}" "a name of the private list" "${line}"
			fi
		done
	done < "${WTFBSD_DENYLIST}"
}

for file in "$@"; do
	check_file "${file}"
done
check_denylist "$@"

if [ "${violations}" -gt 0 ]; then
	exit 1
fi
exit 0

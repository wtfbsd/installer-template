# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The check of an IPv4 address, in one place: the network section checks
# the answers with it and the adapter checks the command line with it.

# arg_ipv4_ok <address> — four decimal numbers from 0 to 255 and nothing
# else.
arg_ipv4_ok() {
	case "$1" in
		*[!0-9.]*|'') return 1 ;;
	esac
	printf '%s\n' "$1" | awk -F. '
		NR > 1 { exit 1 }
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]{1,3}$/ || $i > 255) exit 1 }
	'
}

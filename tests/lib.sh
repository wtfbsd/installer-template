# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Shared helpers for the test cases.  A case is a standalone POSIX sh script
# that sources this file, runs its checks and ends with finish.

fails=0

check() { # check <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
		fails=$((fails + 1))
	fi
}

check_rc() { # check_rc <name> <expected exit code> <actual exit code>
	if [ "$2" -eq "$3" ] 2>/dev/null; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$3"
		fails=$((fails + 1))
	fi
}

check_contains() { # check_contains <name> <needle> <haystack>
	case "$3" in
		*"$2"*) printf 'ok   %s\n' "$1" ;;
		*) printf 'FAIL %s: [%s] does not contain [%s]\n' "$1" "$3" "$2"
		   fails=$((fails + 1)) ;;
	esac
}

check_absent() { # check_absent <name> <needle> <haystack>
	case "$3" in
		*"$2"*) printf 'FAIL %s: [%s] contains [%s]\n' "$1" "$3" "$2"
		       fails=$((fails + 1)) ;;
		*) printf 'ok   %s\n' "$1" ;;
	esac
}

tui_run() { # tui_run <answer script> — run the text front end with the
	# stand-in dialog tool.  The environment of the caller is inherited, so a
	# case can point the front end at a scratch directory.  The exit code is
	# left in tui_rc and everything the front end printed in tui_out.
	rm -f "${BSDDIALOG_LOG:-}" "${BSDDIALOG_STATE:-}"
	tui_rc=0
	tui_out=$(BSDDIALOG_LOG="${BSDDIALOG_LOG}" BSDDIALOG_SCRIPT="$1" \
		BSDDIALOG_STATE="${BSDDIALOG_STATE}" \
		"${root}/bin/installer-tui" 2>&1) || tui_rc=$?
}

rmrf() { # rmrf <path> <guardroot> — rm -rf only for non-empty paths under root
	[ -n "${1:-}" ] || { printf 'rmrf: empty path\n' >&2; return 1; }
	[ -n "${2:-}" ] || { printf 'rmrf: empty guard root\n' >&2; return 1; }
	[ "$1" != "$2" ] || { printf 'rmrf: refusing guard root itself: %s\n' "$1" >&2; return 1; }
	case $1 in "$2"/*) ;; *) printf 'rmrf: refusing path outside %s: %s\n' "$2" "$1" >&2; return 1 ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

finish() { # finish — report the case result
	if [ "$fails" -eq 0 ]; then
		printf 'all checks passed\n'
		return 0
	fi
	printf '%s check(s) failed\n' "$fails"
	return 1
}

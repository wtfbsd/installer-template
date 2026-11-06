#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A signal ends a run: it does not only run the cleanup of the run and
# let the script go on where it was.
#
# A trap that names the exit and a signal in the same command does
# exactly that: the handler runs when the signal comes, the script
# carries on, and an installation that was interrupted goes on writing to
# the target of the machine.  Every signal has a handler of its own, and
# the handler ends the run with the code of the signal: 129 for HUP, 130
# for INT and 143 for TERM.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-traps.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# The scripts of the installer.
scripts=''
for part in bin lib adapters sections.d; do
	for file in "${root}/${part}"/*; do
		[ -f "${file}" ] || continue
		case "${file}" in
			*.py) continue ;;
		esac
		scripts="${scripts} ${file}"
	done
done
scripts="${scripts} ${root}/install-into-stage.sh"

# The traps that name the exit and a signal in the same command.  A trap
# that resets the handlers ("trap - ...") names no handler at all and is
# not one of them.
bad=''
for file in ${scripts}; do
	while IFS= read -r line; do
		# The line without the space in front of it.
		line=${line#"${line%%[![:space:]]*}"}
		case "${line}" in
			'#'*) continue ;;
			'trap '*) : ;;
			*) continue ;;
		esac
		case "${line}" in
			'trap -'*) continue ;;
		esac
		case "${line}" in
			*EXIT*) : ;;
			*) continue ;;
		esac
		case "${line}" in
			*INT*|*TERM*|*HUP*)
				bad="${bad}${bad:+ }${file##*/}"
				break ;;
		esac
	done < "${file}"
done

check "no script traps the exit and a signal with one handler" "" "${bad}"

finish

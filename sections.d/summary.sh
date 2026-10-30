#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# summary: the answers the installer is about to use.  The section itself
# holds no work; it checks that the answers are complete.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

cmd_probe() {
	printf '{"section":"summary","fields":['
	printf '"product","keymap","timezone","disk","user","network"]}\n'
}

cmd_validate() {
	answers_get DISK >/dev/null || die 2 'no disk was chosen'
	answers_get USER_NAME >/dev/null || die 2 'no user name was given'
	answers_get KEYMAP >/dev/null || die 2 'no keyboard layout was chosen'
	answers_get TIMEZONE >/dev/null || die 2 'no time zone was chosen'
}

cmd_apply() {
	:
}

cmd_verify() {
	:
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate) cmd_validate "$@" ;;
	apply) cmd_apply "$@" ;;
	verify) cmd_verify "$@" ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

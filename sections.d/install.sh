#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# install: the work itself.  The adapter for the operating system carries it
# out and prints one progress line per step.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

OS=$(config_value OS) || exit 2

cmd_probe() {
	printf '{"section":"install","steps":["disk","files","settings","boot"]}\n'
}

cmd_validate() {
	:
}

cmd_apply() {
	adapter_cmd apply-install
}

cmd_verify() {
	adapter_cmd verify-install
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate) cmd_validate "$@" ;;
	apply) cmd_apply "$@" ;;
	verify) cmd_verify "$@" ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

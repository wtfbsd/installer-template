#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# welcome: the first page of the installer.  It has no work of its own; it
# only reports what the installation is about to be.

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
	product=$(config_value PRODUCT_NAME) || exit 2
	slug=$(config_value PRODUCT_SLUG) || exit 2
	system=$(config_value OS) || exit 2
	printf '{"section":"welcome","product":"%s","slug":"%s","os":"%s"}\n' \
		"${product}" "${slug}" "${system}"
}

cmd_validate() {
	:
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

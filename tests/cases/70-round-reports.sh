#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The round reports are never part of the repository: they are written while
# a round runs and they are ignored.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

check_contains "the reports are ignored" "ROUND-REPORT" \
	"$(cat "${root}/.gitignore" 2>/dev/null || true)"

tracked=$(git ls-files 2>/dev/null | grep -c '^ROUND-REPORT' || true)
check "no round report is tracked" "0" "${tracked}"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# No dialog ever starts with the second button focused: the primary action is
# always the one Enter accepts.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

token='--default'"no"
token2='--default-'"no"
token3='--default-'"button cancel"

# The round reports are never tracked and they name the rule, so they are
# left out of the scan.
hits=$(grep -rIl --exclude-dir=.git --exclude='ROUND-REPORT*.md' -- \
	"${token}" . 2>/dev/null || true)
check "no dialog defaults to the second button" "" "${hits}"

hits=$(grep -rIl --exclude-dir=.git --exclude='ROUND-REPORT*.md' -- \
	"${token2}" . 2>/dev/null || true)
check "no dialog turns the default answer off" "" "${hits}"

hits=$(grep -rIl --exclude-dir=.git --exclude='ROUND-REPORT*.md' -- \
	"${token3}" . 2>/dev/null || true)
check "no dialog names the second button as the default" "" "${hits}"

finish

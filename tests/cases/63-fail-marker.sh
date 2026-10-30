#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The mark of a rehearsal that failed once lives in a directory of the run and
# never in a path that everybody shares: a run that has no state directory
# of its own gets a directory of its own, and that directory is gone when
# the run ends.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-marker.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

scratch="${tmp}/scratch"
mkdir -p "${scratch}"

TMPDIR="${scratch}"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture-fail-once.conf"
export TMPDIR INSTALLER_ADAPTER_FIXTURE

# The run has no state directory of its own: the mark of the failure has a
# home of its own.
unset INSTALLER_STATE_DIR || :

rc=0
sh "${root}/adapters/freebsd.sh" apply-install >/dev/null 2>&1 || rc=$?
check "the rehearsal fails" "3" "${rc}"

# The mark of the failure is not kept: the run that comes after it fails as
# well, because the mark lived in the directory of the run that is over.
rc=0
sh "${root}/adapters/freebsd.sh" apply-install >/dev/null 2>&1 || rc=$?
check "the rehearsal after it fails as well" "3" "${rc}"

# The mark is never left in a path that everybody shares.
if [ -e "${scratch}/install-failed-once" ]; then
	printf 'FAIL the mark of the failure is left in %s\n' "${scratch}"
	fails=$((fails + 1))
else
	printf 'ok   the mark of the failure is not left behind\n'
fi

# The directory of the run is gone when the run ends.
left=$(ls -A "${scratch}" | wc -l | tr -d ' ')
check "the directory of the run is gone" "0" "${left}"

finish

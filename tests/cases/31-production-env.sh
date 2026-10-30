#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installer the way production runs it: the caller sets nothing at all.
# The front end has to make the answers file itself and it has to tell the
# backend where it is, because the backend reads the answers from the
# environment.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-production.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# The tree the installer runs from.  It is a copy so that the run does not
# write into the repository.
tree="${tmp}/tree"
mkdir -p "${tree}"
cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" \
	"${root}/installer.conf" "${tree}/"
rmrf "${tree}/lib/__pycache__" "${tmp}"

# The rehearsal of the installation: the hardware the run sees.
cat > "${tree}/rehearsal.conf" <<'REHEARSAL'
DISKS=ada0|Samsung SSD 860|500107862016
INTERFACES=em0|Intel I219-LM
REHEARSAL

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE

rc=0
out=$(env -u INSTALLER_ANSWERS -u INSTALLER_LOG -u INSTALLER_STATE_PARENT \
	-u INSTALLER_ADAPTER_FIXTURE -u INSTALLER_CONF -u INSTALLER_ROOT \
	-u INSTALLER_LIBEXEC -u INSTALLER_MEDIA_MOUNT \
	TMPDIR="${tmp}" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${tree}/bin/installer-tui" 2>&1) || rc=$?

check_rc "the installer finishes when the caller sets nothing" 0 "${rc}"

dialog_log=$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)
check_contains "the run reaches the finished page" "is installed" "${dialog_log}"

# The log of the run is kept in the place the installer documents.
log="${tmp}/wtfbsd-installer.log"
log_text=$(cat "${log}" 2>/dev/null || true)
check_absent "the disk check did not fail for a missing answers file" \
	"no disk was chosen" "${log_text}"
check_contains "the installation ran" "install: writing the system files" \
	"${log_text}"

check_absent "the run did not report a failed installation" \
	"did not finish" "${out}"

finish

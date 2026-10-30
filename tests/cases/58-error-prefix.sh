#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The errors of the front end say that the front end is the one that
# stopped: the message of the front end begins with the name of the front
# end and not with the name of the backend.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-prefix.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_ANSWERS INSTALLER_LOG

# The state directory cannot be made: the parent of the state is a file.
: > "${tmp}/a-file"
rc=0
out=$(INSTALLER_STATE_PARENT="${tmp}/a-file/state" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

check_contains "the error of the front end names the front end" \
	"installer-tui: cannot create the state directory" "${out}"
check_absent "the error of the front end does not name the backend" \
	"installer-backend:" "${out}"

# The answers cannot be written: the gate refuses to gate them.
stub="${tmp}/stub"
mkdir -p "${stub}"
cat > "${stub}/python3" <<'STUB'
#!/bin/sh
for arg in "$@"; do
	case "$arg" in
		*/gating.py)
			printf 'gating: the stand-in refuses to gate\n' >&2
			exit 2
			;;
	esac
done
exec "${STUB_PYTHON}" "$@"
STUB
chmod 755 "${stub}/python3"
STUB_PYTHON=$(command -v python3)
export STUB_PYTHON

rc=0
out=$(PATH="${stub}:${PATH}" \
	INSTALLER_STATE_PARENT="${tmp}" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

check_contains "the error of the front end names the front end" \
	"installer-tui: cannot write the answers" "${out}"
check_absent "the error of the front end does not name the backend" \
	"installer-backend:" "${out}"

# The backend keeps the name of the backend: its message goes to the log of
# the run.
rc=0
out=$(INSTALLER_CONF="${root}/tests/fixtures/installer-netbsd.conf" \
	INSTALLER_STATE_PARENT="${tmp}" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?
check_contains "the error of the backend names the backend" \
	"installer-backend: adapter not implemented for netbsd" \
	"$(cat "${INSTALLER_LOG}" 2>/dev/null || true)"

finish

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The answers reach the file of the answers through the gate: the gate
# writes a file of its own and the file of the answers is only replaced
# when the gate was happy with the answers.  A gate that fails leaves no
# answers behind and the run stops.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-answers.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A stand-in for python3 that refuses to gate the answers and hands every
# other call to the real python3.
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

rm -f "${INSTALLER_ANSWERS}"
rc=0
out=$(PATH="${stub}:${PATH}" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

if [ "${rc}" -ne 0 ]; then
	printf 'ok   the run stops when the answers cannot be gated\n'
else
	printf 'FAIL the run ended with 0 when the answers could not be gated\n'
	fails=$((fails + 1))
fi

check_contains "the run says that the answers cannot be written" \
	"cannot write the answers" "${out}"

if [ ! -e "${INSTALLER_ANSWERS}" ]; then
	printf 'ok   no answers file is left behind\n'
else
	printf 'FAIL the answers file is there: %s\n' "$(cat "${INSTALLER_ANSWERS}")"
	fails=$((fails + 1))
fi

# The run stops before the installation: nothing was installed.
check_absent "nothing was installed" "is installed" \
	"$(cat "${BSDDIALOG_LOG}" 2>/dev/null || true)"

finish

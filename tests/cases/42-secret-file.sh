#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The password of the account is written to a file of its own: the file is
# made in a file of its own and moved into place, and a file that the run
# did not write is never written over.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-secret.XXXXXX")
tmp_root=$(dirname "${tmp}")
cleanup_tmp() {
	chmod -R u+rwX "${tmp}" 2>/dev/null || :
	rmrf "${tmp}" "${tmp_root}" || :
}
trap 'cleanup_tmp' EXIT INT TERM HUP

# The helper of the password file.
. "${root}/lib/accounts.sh"

secrets="${tmp}/secrets"
mkdir -p "${secrets}"

# A password file that is not there is written.
if write_secret_file "${secrets}" 'the-password' 2>/dev/null; then
	printf 'ok   the password file is written\n'
else
	printf 'FAIL the password file is not written\n'
	fails=$((fails + 1))
fi
check_contains "the password file holds the password" \
	"the-password" "$(cat "${secrets}/user.pass" 2>/dev/null || true)"

mode=$(stat -c %a "${secrets}/user.pass" 2>/dev/null || stat -f %Lp "${secrets}/user.pass" 2>/dev/null || printf '')
check "the password file is private" "600" "${mode}"

# A password file that is there is never written over.
printf 'the-old-password\n' > "${secrets}/user.pass"
rc=0
write_secret_file "${secrets}" 'the-new-password' >/dev/null 2>&1 || rc=$?
check_rc "a password file that is there is refused" 1 "${rc}"
check_contains "the password file kept its password" \
	"the-old-password" "$(cat "${secrets}/user.pass" 2>/dev/null || true)"
check_absent "the password file was not written over" \
	"the-new-password" "$(cat "${secrets}/user.pass" 2>/dev/null || true)"

# No file of its own is left behind.
left=$(find "${secrets}" -name '.user.pass.*' | wc -l | tr -d ' ')
check "no file of its own is left behind" "0" "${left}"

# The front end refuses a password file that the run did not write.
BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A stand-in for the dialog tool that puts a password file in the state
# directory of the run before the summary page.  The directory of the
# secrets and the state directory itself are made read-only afterwards, so
# that the file survives the end of the run.
cat > "${tmp}/wrap-bsddialog" <<'WRAP'
#!/bin/sh
calls=$(cat "${BSDDIALOG_STATE}" 2>/dev/null || printf '0')
if [ "${calls}" -eq 9 ] && [ -n "${INSTALLER_STATE_DIR:-}" ] &&
	[ -d "${INSTALLER_STATE_DIR}" ]; then
	mkdir -p "${INSTALLER_STATE_DIR}/secrets"
	printf 'the-old-password\n' > "${INSTALLER_STATE_DIR}/secrets/user.pass"
	chmod 600 "${INSTALLER_STATE_DIR}/secrets/user.pass"
	chmod 500 "${INSTALLER_STATE_DIR}/secrets"
	chmod 500 "${INSTALLER_STATE_DIR}"
fi
exec "${REAL_BSDDIALOG}" "$@"
WRAP
chmod 755 "${tmp}/wrap-bsddialog"

rc=0
out=$(REAL_BSDDIALOG="${BSDDIALOG}" \
	BSDDIALOG="${tmp}/wrap-bsddialog" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

if [ "${rc}" -ne 0 ]; then
	printf 'ok   the run stops when the password file is not its own\n'
else
	printf 'FAIL the run ended with 0 when the password file was not its own\n'
	fails=$((fails + 1))
fi

check_contains "the run says that the answers cannot be written" \
	"cannot write the answers" "${out}"

state_dir=$(find "${tmp}" -maxdepth 1 -type d -name 'wtfbsd-installer.*' |
	head -1)
if [ -n "${state_dir}" ] && [ -f "${state_dir}/secrets/user.pass" ]; then
	check_contains "the password file that the run did not write kept its password" \
		"the-old-password" "$(cat "${state_dir}/secrets/user.pass")"
	check_absent "the password file that the run did not write was not written over" \
		"s3cret-pass" "$(cat "${state_dir}/secrets/user.pass")"
else
	printf 'FAIL the password file of the run is not there to look at\n'
	fails=$((fails + 1))
fi

finish

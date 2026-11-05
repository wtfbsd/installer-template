#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The password of the account is never written anywhere by the text front
# end: only its crypt hash is, to a file of mode 0600 in a directory of mode
# 0700.  The hash file is made in a file of its own and moved into place,
# and a hash file that the run did not write is never written over.

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

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf"
INSTALLER_STATE_PARENT="${tmp}/state"
mkdir -p "${INSTALLER_STATE_PARENT}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_ADAPTER_FIXTURE
export INSTALLER_STATE_PARENT INSTALLER_ANSWERS INSTALLER_LOG

# A stand-in for the dialog tool that looks at the disk before every
# dialog: every file under the parent of the state that holds the password
# is written down, and the hash file and its directory are described.
cat > "${tmp}/spy-bsddialog" <<'SPY'
#!/bin/sh
grep -rlF -- 's3cret-pass' "${INSTALLER_STATE_PARENT}" "${INSTALLER_ANSWERS}" \
	"${INSTALLER_LOG}" 2>/dev/null >> "${SPY_FOUND}" || :
if [ -n "${INSTALLER_STATE_DIR:-}" ] && [ -f "${INSTALLER_STATE_DIR}/secrets/user.hash" ]; then
	f="${INSTALLER_STATE_DIR}/secrets/user.hash"
	{
		printf 'HASH %s\n' "$(head -n 1 "${f}")"
		printf 'MODE %s %s\n' "$(stat -c %a "${f}" 2>/dev/null || stat -f %Lp "${f}")" \
			"$(stat -c %a "${f%/*}" 2>/dev/null || stat -f %Lp "${f%/*}")"
	} >> "${SPY_HASH}"
fi
exec "${REAL_BSDDIALOG}" "$@"
SPY
chmod 755 "${tmp}/spy-bsddialog"
: > "${tmp}/spy.found"
: > "${tmp}/spy.hash"

rc=0
out=$(REAL_BSDDIALOG="${BSDDIALOG}" BSDDIALOG="${tmp}/spy-bsddialog" \
	SPY_FOUND="${tmp}/spy.found" SPY_HASH="${tmp}/spy.hash" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?
check_rc "the run installs" 0 "${rc}"
check "no file ever held the password" "" "$(sort -u "${tmp}/spy.found")"
check_absent "the answers do not hold the password" "s3cret-pass" \
	"$(cat "${INSTALLER_ANSWERS}")"
check_absent "the answers name no file of the password itself" "USER_PASSFILE" \
	"$(cat "${INSTALLER_ANSWERS}")"
check_absent "the log does not hold the password" "s3cret-pass" \
	"$(cat "${INSTALLER_LOG}" 2>/dev/null || true)"
hash=$(sed -n 's/^HASH //p' "${tmp}/spy.hash" | head -1)
check_contains "the hash file holds a SHA-512 crypt hash" '$6$' "${hash}"
ok=$(printf 's3cret-pass\n' | python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[2])
import passhash
pw = sys.stdin.readline().rstrip("\n")
print("yes" if passhash.sha512_crypt(pw, sys.argv[1]) == sys.argv[1] else "no")' \
	"${hash}" "${root}/lib")
check "the hash is the hash of the password typed" yes "${ok}"
check "the hash file is 0600 in a 0700 directory" "MODE 600 700" \
	"$(grep '^MODE' "${tmp}/spy.hash" | sort -u)"
check "the hash is made once for one password" 1 \
	"$(sed -n 's/^HASH //p' "${tmp}/spy.hash" | sort -u | wc -l | tr -d ' ')"

# The front end refuses a hash file that the run did not write.  A
# stand-in for the dialog tool puts one in the state directory of the run
# before the summary page; the directory of the secrets and the state
# directory itself are made read-only afterwards, so that the file survives
# the end of the run.
cat > "${tmp}/wrap-bsddialog" <<'WRAP'
#!/bin/sh
calls=$(cat "${BSDDIALOG_STATE}" 2>/dev/null || printf '0')
if [ "${calls}" -eq 14 ] && [ -n "${INSTALLER_STATE_DIR:-}" ] &&
	[ -d "${INSTALLER_STATE_DIR}" ]; then
	mkdir -p "${INSTALLER_STATE_DIR}/secrets"
	printf '$6$planted$hash\n' > "${INSTALLER_STATE_DIR}/secrets/user.hash"
	chmod 600 "${INSTALLER_STATE_DIR}/secrets/user.hash"
	chmod 500 "${INSTALLER_STATE_DIR}/secrets"
	chmod 500 "${INSTALLER_STATE_DIR}"
fi
exec "${REAL_BSDDIALOG}" "$@"
WRAP
chmod 755 "${tmp}/wrap-bsddialog"
rm -f "${BSDDIALOG_STATE}" "${BSDDIALOG_LOG}"

rc=0
out=$(REAL_BSDDIALOG="${BSDDIALOG}" \
	BSDDIALOG="${tmp}/wrap-bsddialog" \
	BSDDIALOG_SCRIPT="${root}/tests/fixtures/answers-happy.txt" \
	"${root}/bin/installer-tui" 2>&1) || rc=$?

if [ "${rc}" -ne 0 ]; then
	printf 'ok   the run stops when the hash file is not its own\n'
else
	printf 'FAIL the run ended with 0 when the hash file was not its own\n'
	fails=$((fails + 1))
fi
check_contains "the run says that the answers cannot be written" \
	"cannot write the answers" "${out}"

state_dir=$(find "${INSTALLER_STATE_PARENT}" -maxdepth 1 -type d -name 'wtfbsd-installer.*' | head -1)
if [ -n "${state_dir}" ] && [ -f "${state_dir}/secrets/user.hash" ]; then
	check "the hash file that the run did not write kept its content" \
		'$6$planted$hash' "$(cat "${state_dir}/secrets/user.hash")"
else
	printf 'FAIL the hash file of the run is not there to look at\n'
	fails=$((fails + 1))
fi

finish

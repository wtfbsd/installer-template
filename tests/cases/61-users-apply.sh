#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The account of the installed system is made by the install step: the
# section of the accounts checks the answers and says where the account is
# made.  The check of the answers refuses a name that is an account of the
# system that is installed.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-apply.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"

answers="${tmp}/answers.conf"

# The apply of the accounts makes no account: the install step does.
printf 'USER_NAME=tester\nUSER_AUTH=none\n' > "${answers}"
rc=0
out=$(INSTALLER_ANSWERS="${answers}" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
	"${backend}" users apply 2>&1) || rc=$?
check_rc "the apply of the accounts does nothing" 0 "${rc}"
check_contains "the apply says that the install step makes the account" \
	"install step" "${out}"

# The check of the answers refuses a name that is an account of the system
# that is installed.
target="${tmp}/target"
mkdir -p "${target}/etc"
printf 'root:*:%s:%s:Unixes system administrator:/root:/bin/sh\n' 0 0 \
	> "${target}/etc/master.passwd"
printf 'targetuser:*:%s:%s:An account of the system:/var/empty:/bin/sh\n' \
	1001 1001 >> "${target}/etc/master.passwd"

fixture="${tmp}/target-fixture.conf"
printf 'DISKS=ada0|Samsung SSD 860|500107862016\nINTERFACES=em0\n' \
	> "${fixture}"
printf 'TARGET_ROOT=%s\n' "${target}" >> "${fixture}"

printf 'USER_NAME=targetuser\nUSER_AUTH=none\n' > "${answers}"
rc=0
out=$(INSTALLER_ANSWERS="${answers}" \
	INSTALLER_ADAPTER_FIXTURE="${fixture}" \
	"${backend}" users validate 2>&1) || rc=$?
check_rc "a name that is an account of the installed system is refused" \
	2 "${rc}"
check_contains "the refusal names the account" "targetuser" "${out}"

# A name that is not an account of the system that is installed is
# accepted.
printf 'USER_NAME=tester\nUSER_AUTH=none\n' > "${answers}"
rc=0
INSTALLER_ANSWERS="${answers}" \
	INSTALLER_ADAPTER_FIXTURE="${fixture}" \
	"${backend}" users validate >/dev/null 2>&1 || rc=$?
check_rc "a name that is not an account of the installed system is accepted" \
	0 "${rc}"

finish

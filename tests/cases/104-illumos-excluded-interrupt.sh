#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The illumos adapter keeps the reason of an exclusion in a temporary file
# while lib/illumos.py runs.  The function runs in a command substitution,
# whose subshell has none of the traps of the run: an interrupt of that
# subshell must not leave the file behind.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-excluded.XXXXXX")
tmp_root=$(dirname "${tmp}")
cleanup_case() {
	[ ! -f "${tmp}/py.pid" ] || kill -KILL "$(cat "${tmp}/py.pid")" 2>/dev/null || :
	rmrf "${tmp}" "${tmp_root}" || :
}
trap 'cleanup_case' EXIT INT TERM HUP

mkdir -m 700 "${tmp}/runtmp" "${tmp}/bin"
# A slow stand-in named python3: the case interrupts the subshell while it runs.
cat > "${tmp}/bin/python3" <<'STUB'
#!/bin/sh
printf '%s\n' "$$" > "${CASE_PY_PID}.tmp" && mv "${CASE_PY_PID}.tmp" "${CASE_PY_PID}"
exec sleep 30
STUB
chmod 755 "${tmp}/bin/python3"

# os_excluded_disks of the illumos adapter, with the globals it reads.
body=$(awk '/^os_excluded_disks\(\)/ { p=1 } p { print } p && /^[})]$/ { exit }' adapters/illumos.sh)
[ -n "${body}" ] || { printf 'os_excluded_disks not found\n' >&2; exit 1; }

(
	CASE_PY_PID="${tmp}/py.pid"
	export CASE_PY_PID
	PATH="${tmp}/bin:${PATH}"
	tmp_root="${tmp}/runtmp"
	rehearsal=''
	cannot_tell() { exit 3; }
	eval "${body}"
	_x=$(os_excluded_disks c1t0d0) || :
) &
outer=$!

waited=0
while [ ! -f "${tmp}/py.pid" ] && [ "${waited}" -lt 100 ]; do
	waited=$((waited + 1))
	sleep 0.1
done
check "the slow stub ran" yes "$([ -f "${tmp}/py.pid" ] && echo yes || echo no)"
py=$(cat "${tmp}/py.pid" 2>/dev/null || echo 0)
# The parent of the stub is the inner substitution (_out=$(...)), whose
# failure the function handles; its parent is the subshell that runs the
# function (_x=$(os_excluded_disks ...)): that one is interrupted.
inner=$(ps -o ppid= -p "${py}" 2>/dev/null | tr -d ' ')
sub=$(ps -o ppid= -p "${inner}" 2>/dev/null | tr -d ' ')
made=no
for _f in "${tmp}/runtmp"/wtfbsd-excluded.*; do [ -e "${_f}" ] && made=yes; done
check "the file of the reason exists while the stub runs" yes "${made}"

kill -TERM "${sub}" 2>/dev/null || :
kill -KILL "${py}" 2>/dev/null || :
wait "${outer}" 2>/dev/null || :

left=''
for _f in "${tmp}/runtmp"/*; do
	[ -e "${_f}" ] || continue
	left="${left} ${_f##*/}"
done
check "an interrupted subshell leaves no file of the reason behind" "" "${left}"

finish

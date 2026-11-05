#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The pictures of each system show the devices of that system: the fixture
# tools/render-fixtures names for it is made of its own captured outputs
# (disks of tests/fixtures/captures/<os>, adapters of its hw-captures), and
# its Disk, Network and Hardware pages name no device of another system.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-devices.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

entry() { sed -n "s/^$1=//p" tools/render-fixtures | head -n 1; }

for os in netbsd openbsd dragonfly illumos; do
	fixture=$(entry "${os}")
	fixture=${fixture%% *}
	f="tests/fixtures/disks/${fixture}"
	check "${os}: tools/render-fixtures names a fixture of its own" yes \
		"$([ -f "${f}" ] && [ "${fixture}" != dual-os.conf ] && echo yes || echo "no (${fixture})")"
	# Its disks are disks of its captures, its adapters those of its
	# hardware captures, its hardware read from them.
	bad=''
	for d in $(sed -n 's/^DISKS=//p' "${f}" | tr ',' '\n' | cut -d'|' -f1); do
		{ ls -R "tests/fixtures/captures/${os}" | grep -q "${d}" || grep -rqw "${d}" "tests/fixtures/captures/${os}"; } || bad="${bad} ${d}"
	done
	for i in $(sed -n 's/^INTERFACES=//p' "${f}" | tr ',' '\n' | cut -d'|' -f1); do
		grep -rqw "${i}" "tests/fixtures/hw-captures/${os}" || bad="${bad} ${i}"
	done
	grep -q "^HARDWARE_CAPTURE=../hw-captures/${os}\$" "${f}" || bad="${bad} hardware"
	check "${os}: its disks, adapters and hardware come from its captures" "" "${bad}"
done

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 71) % 400) + 3500 ))
	broadwayd ":${n}" >/dev/null 2>&1 &
	bpid=$!
	for wait in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "${bpid}" 2>/dev/null || break
		if BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway bin/installer-gui --check >/dev/null 2>&1; then
			ready=yes
			break
		fi
		sleep 0.5
	done
	[ "${ready}" = no ] || break
	kill "${bpid}" 2>/dev/null || :
done
trap 'kill "${bpid}" 2>/dev/null; rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
check "broadwayd started" yes "${ready}"

cat > "${tmp}/pages.json" <<'JSON'
[{"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "page"}},
 {"name": "network", "page": "network", "full": false, "state": {"report": "page"}},
 {"name": "hardware", "page": "hardware", "full": false, "state": {"report": "page"}}]
JSON
# The device names of every system; a page of one names none of the others
# (FreeBSD's da0 is DragonFly's too, NetBSD's sd0 OpenBSD's: those are
# left out of the other's list).
cat > "${tmp}/names.py" <<'PY'
import json, re, sys
NAMES = {
    "freebsd": r"(ada|nda|nvd|vtbd|vtnet|em|igb|iwm|iwlwifi|psm|ukbd|i915kms|vgapci)\d+|i915kms",
    "netbsd": r"(wd|ld|vioif|wm|pckbd|pms)\d+",
    "openbsd": r"(vio|softraid|pckbd|pms|inteldrm)\d+",
    "dragonfly": r"(vbd|vtnet|ad)\d+",
    "illumos": r"c\d+(t[0-9A-F]+)?d\d+|vioif|kb8042|mouse8042",
}
os_name, outdir = sys.argv[1], sys.argv[2]
texts = []
for page in ("disk", "network", "hardware"):
    texts += json.load(open(f"{outdir}/{page}.page.json"))["texts"]
found = set()
for other, pattern in NAMES.items():
    if other == os_name or (other, os_name) in {("freebsd", "dragonfly"), ("netbsd", "openbsd"),
                                                ("dragonfly", "freebsd"), ("openbsd", "netbsd"),
                                                ("netbsd", "illumos"), ("illumos", "netbsd")}:
        continue
    for text in texts:
        for m in re.finditer(r"\b(" + pattern + r")\b", text):
            found.add(m.group(0))
print(" ".join(sorted(found)))
PY
for os in freebsd netbsd openbsd dragonfly illumos; do
	sed "s/^OS=.*/OS=${os}/" installer.conf | grep -v '^MIN_DISK_GB=' > "${tmp}/${os}.conf"
	e=$(entry "${os}")
	min=$(printf '%s\n' "${e}" | sed -n 's/.* min_disk_gb=\([0-9]*\).*/\1/p')
	[ -z "${min}" ] || printf 'MIN_DISK_GB=%s\n' "${min}" >> "${tmp}/${os}.conf"
	mkdir -p "${tmp}/${os}"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="${tmp}/${os}.conf" INSTALLER_MNTTAB=/nonexistent \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/${e%% *}" \
		bin/installer-gui --render "${tmp}/pages.json" --size 1024x768 --screenshots "${tmp}/${os}" \
		> "${tmp}/${os}.log" 2>&1 || cat "${tmp}/${os}.log" >&2
	check "${os}: the Disk, Network and Hardware pages name no device of another system" "" \
		"$(python3 -I -B "${tmp}/names.py" "${os}" "${tmp}/${os}" 2>&1)"
done

# The data disks in the summary, in the words of their filesystem: a pool
# only for ZFS.
summary() { # summary <os> <system disk> <data disk>
	printf '[{"name": "summary", "page": "summary", "full": false, "state": {"report": "page"}, "disk_state": {"mode": "erase", "selected": ["%s"], "usage": "together", "data_disks": ["%s"]}}]\n' \
		"$2" "$3" > "${tmp}/summary-$1.json"
	e=$(entry "$1")
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="${tmp}/$1.conf" INSTALLER_MNTTAB=/nonexistent \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/${e%% *}" \
		bin/installer-gui --render "${tmp}/summary-$1.json" --size 1024x768 --screenshots "${tmp}/$1" \
		> "${tmp}/summary-$1.log" 2>&1 || cat "${tmp}/summary-$1.log" >&2
	python3 -I -B -c 'import json, sys
t = json.load(open(sys.argv[1]))["texts"]
print(" | ".join(x for x in t if "/data" in x))' "${tmp}/$1/summary.page.json" 2>&1
}
out=$(summary openbsd sd2 sd1)
check "openbsd: an FFS data disk is worded as one, no pool" "erase, FFS on /data no" \
	"$(case "${out}" in *"erase, FFS on /data"*) printf 'erase, FFS on /data' ;; *) printf '%s' "${out}" ;; esac) $(case "${out}" in *pool*) echo yes ;; *) echo no ;; esac)"
out=$(summary freebsd nda0 da0)
check "freebsd: a ZFS data disk is a pool" yes \
	"$(case "${out}" in *"erase, ZFS pool data (Single disk) on /data"*) echo yes ;; *) printf '%s' "${out}" ;; esac)"

finish

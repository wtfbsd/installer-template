#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Everything the Disk page offers that the install command decides comes
# from its capabilities, not from the built-in table: an install command
# that cannot encrypt the system ("encryption": "") gets no box and no
# passphrase, a line that says so, and a plan with encryption is refused;
# the filesystems and the layouts of the data disks are the command's too.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-capspage.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

sed 's/^OS=.*/OS=netbsd/' installer.conf > "${tmp}/netbsd.conf"
# An install command of NetBSD that cannot encrypt the system, with
# filesystems and layouts other than those of the built-in table.
cat > "${tmp}/netbsd-install" <<'SH'
#!/bin/sh
[ "${1-}" = --capabilities ] || exit 64
cat <<'JSON'
{"modes": ["erase"], "data_pools": true, "encryption": "", "boot": ["uefi", "bios"],
 "filesystems": [["ffs", "FFSv2"], ["lfs", "LFS"]],
 "layouts": [{"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1},
             {"ident": "raid1", "title": "RAID 1 (RAIDframe)", "min_disks": 2}]}
JSON
SH
chmod 755 "${tmp}/netbsd-install"

# The plan: encryption on is refused, with a clear message.
out=$(INSTALLER_CONF="${tmp}/netbsd.conf" INSTALLER_INSTALL_COMMAND="${tmp}/netbsd-install" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/three-disks.conf" \
	bin/installer-backend disk probe | python3 -I -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import diskplan
d = json.load(sys.stdin)["detail"]
p = {"version": 1, "mode": "erase", "disks": ["ada0"], "layout": "single", "filesystem": "ffs",
     "encryption": {"enabled": True, "swap": False}}
on = diskplan.validate(p, d, "netbsd")
off = diskplan.validate(dict(p, encryption={"enabled": False, "swap": False}), d, "netbsd")
print([e for e in on if "encrypt" in e], off)' "${root}/lib")
check "no encryption offered: a plan with encryption is refused, without it it is good" \
	"['NetBSD: no system encryption'] []" "${out}"

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 61) % 400) + 2700 ))
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

cat > "${tmp}/enc.json" <<'JSON'
[{"name": "noenc", "page": "disk", "full": false,
  "state": {"mode": "erase", "usage": "together", "selected": ["ada0"], "layout": "single",
            "advanced": true, "report": "encryption"}}]
JSON
mkdir "${tmp}/shots"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${tmp}/netbsd.conf" INSTALLER_INSTALL_COMMAND="${tmp}/netbsd-install" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/three-disks.conf" \
	bin/installer-gui --render "${tmp}/enc.json" --size 1024x768 --screenshots "${tmp}/shots" \
	> "${tmp}/render.log" 2>&1 || cat "${tmp}/render.log" >&2
r() {
	python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/shots/noenc.encryption.json" "$1" 2>&1
}
check "no encryption offered: no box, no passphrase" "False False" \
	"$(r 'str(r["shown"]) + " " + str(r["passphrase_shown"])')"
check "no encryption offered: nothing about it on the page" "" "$(r 'r["note"]')"
check "no encryption offered: the plan does not encrypt" False "$(r 'r["plan"]["enabled"]')"
check "the filesystems are the install command's" "['ffs', 'lfs']" "$(r 'r["filesystems"]')"
check "the layouts of the data disks are the install command's" "['single', 'raid1']" \
	"$(r 'r["data_layouts"]')"

finish

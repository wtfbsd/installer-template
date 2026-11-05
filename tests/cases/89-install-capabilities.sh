#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# What the install command can do comes from the install command itself
# when it can say ("<slug>-install --capabilities", JSON in the shape of
# os_layouts): the verb layouts reports it instead of the adapter's
# built-in table, and falls back without a word when the command does not
# know the option or answers with something unusable.  The boot modes are
# part of it: a command that starts only by UEFI gets no BIOS plan, and the
# Disk page shows the one way as a text, not as a drop-down.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-caps.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
backend="${root}/bin/installer-backend"

sed 's/^OS=.*/OS=dragonfly/' installer.conf > "${tmp}/dragonfly.conf"
sed 's/^OS=.*/OS=openbsd/' installer.conf > "${tmp}/openbsd.conf"

# stub <name> <body> — an install command that answers --capabilities.
stub() {
	{
		printf '#!/bin/sh\n'
		printf '[ "${1-}" = --capabilities ] || { echo "usage" >&2; exit 64; }\n'
		printf '%s\n' "$2"
	} > "${tmp}/$1"
	chmod 755 "${tmp}/$1"
}
stub uefi-only "cat <<'JSON'
{\"modes\": [\"erase\"], \"data_pools\": false, \"boot\": [\"uefi\", \"floppy\"],
 \"filesystems\": [[\"hammer2\", \"HAMMER2\"]], \"encryption\": \"\", \"not_offered\": \"not offered here yet\",
 \"layouts\": [{\"ident\": \"single\", \"title\": \"Single disk\", \"min_disks\": 1, \"max_disks\": 1}]}
JSON"
stub old 'echo "unknown option" >&2; exit 64'
stub junk 'echo "this is not JSON"'
stub nolayouts "echo '{\"boot\": [\"uefi\"]}'"

# caps <conf> <install command> — the capabilities of the disk probe.
caps() {
	INSTALLER_CONF="${tmp}/$1.conf" INSTALLER_INSTALL_COMMAND="$2" \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/three-disks.conf" \
		"${backend}" disk probe | python3 -I -B -c '
import json, sys
c = json.load(sys.stdin)["detail"]["capabilities"]
print(" ".join(l["ident"] for l in c.get("layouts", [])) or "-", "|", c.get("boot", "-"), "|",
      " ".join(f[0] for f in c.get("filesystems", [])) or "-")'
}
check "the install command's own capabilities are used" "single | ['uefi', 'floppy'] | hammer2" \
	"$(caps dragonfly "${tmp}/uefi-only")"
check "an install command without --capabilities: the built-in table, silently" \
	"single raid1 crypto raid1c | - | ffs" "$(caps openbsd "${tmp}/old" 2>&1)"
check "an answer that is not JSON: the built-in table" \
	"single raid1 crypto raid1c | - | ffs" "$(caps openbsd "${tmp}/junk" 2>&1)"
check "an answer without layouts: the built-in table" \
	"single raid1 crypto raid1c | - | ffs" "$(caps openbsd "${tmp}/nolayouts" 2>&1)"
check "no install command at all: the built-in table" \
	"single raid1 crypto raid1c | - | ffs" "$(caps openbsd "${tmp}/missing" 2>&1)"

# A command that hangs: the probe goes on after 10 seconds with the table,
# and the command and what it started are gone.
stub hangs "echo \$\$ > '${tmp}/hangs.pid'; sleep 60 & echo \$! > '${tmp}/hangs.child'; wait"
start=$(date +%s)
got=$(caps openbsd "${tmp}/hangs" 2>&1)
took=$(( $(date +%s) - start ))
check "a command that hangs: the built-in table" "single raid1 crypto raid1c | - | ffs" "${got}"
check "a command that hangs: the probe returns in about 10 seconds" yes \
	"$([ "${took}" -ge 9 ] && [ "${took}" -le 20 ] && echo yes || echo "no (${took} s)")"
gone=yes
for f in hangs.pid hangs.child; do
	[ -s "${tmp}/${f}" ] || { gone="no ${f}"; continue; }
	! kill -0 "$(cat "${tmp}/${f}")" 2>/dev/null || gone="no: ${f} still runs"
done
check "a command that hangs: its process group is killed" yes "${gone}"
# Too much: more than 64 KiB is no answer.
stub floods "yes '{}' | head -c 70000"
check "an answer of more than 64 KiB: the built-in table" \
	"single raid1 crypto raid1c | - | ffs" "$(caps openbsd "${tmp}/floods" 2>&1)"
# The environment of the caller does not reach the command.
stub env-check "[ -z \"\${CALLER_MARK-}\" ] || exit 1; [ \"\${LC_ALL-}\" = C ] || exit 1
cat <<'JSON'
{\"boot\": [\"uefi\"], \"layouts\": [{\"ident\": \"single\", \"title\": \"Single disk\", \"min_disks\": 1, \"max_disks\": 1}]}
JSON"
check "the command runs in a minimal environment" "single | ['uefi'] | -" \
	"$(CALLER_MARK=1 caps openbsd "${tmp}/env-check" 2>&1)"

# The command is checked right before it runs, by the runner itself: not a
# symbolic link, a regular file, writable by its owner only, in a directory
# that is the same, owned by root or (not as root) by the caller.
# marks <path> — an install command that leaves a mark when it runs.
marks() {
	stub "${1##*/}" "echo ran >> '${tmp}/marks'
cat <<'JSON'
{\"layouts\": [{\"ident\": \"single\", \"title\": \"Single disk\", \"min_disks\": 1, \"max_disks\": 1}]}
JSON"
}
runs() { # runs <command> — "<exit code> <marks left>" of the runner
	: > "${tmp}/marks"
	rc=0
	python3 -I -B "${root}/lib/diskplan.py" --check-capabilities "$1" >/dev/null 2>&1 </dev/null || rc=$?
	printf '%s %s\n' "${rc}" "$(wc -l < "${tmp}/marks" | tr -d ' ')"
}
marks "${tmp}/good"
check "the runner runs a command of the caller's own (control)" "0 1" "$(runs "${tmp}/good")"
ln -s "${tmp}/good" "${tmp}/link"
check "the runner refuses a symbolic link swapped in" "1 0" "$(runs "${tmp}/link")"
marks "${tmp}/gw"
chmod 775 "${tmp}/gw"
check "the runner refuses a command others may change" "1 0" "$(runs "${tmp}/gw")"
mkdir "${tmp}/open"
chmod 777 "${tmp}/open"
marks "${tmp}/open-cmd"
mv "${tmp}/open-cmd" "${tmp}/open/cmd"
check "the runner refuses a command in a directory others may change" "1 0" "$(runs "${tmp}/open/cmd")"
check "the runner refuses a path that is not absolute" "1 0" "$(cd "${tmp}" && runs good)"
# A slug that is not one never makes a path: /usr/local/sbin/../../..<tmp>/x
# would be the install command of the slug ../../..<tmp>/x.
mkdir -p "${tmp}/slug"
marks "${tmp}/x-install"
: > "${tmp}/marks"
sed "s|^PRODUCT_SLUG=.*|PRODUCT_SLUG=../../..${tmp}/x|; s/^OS=.*/OS=openbsd/" installer.conf > "${tmp}/badslug.conf"
got=$(INSTALLER_CONF="${tmp}/badslug.conf" adapters/openbsd.sh layouts 2>/dev/null | python3 -I -B -c '
import json, sys; print(" ".join(l["ident"] for l in json.load(sys.stdin)["layouts"]))')
check "a slug that is not one: no command runs, the built-in table" "single raid1 crypto raid1c 0" \
	"${got} $(wc -l < "${tmp}/marks" | tr -d ' ')"

# The plan: BIOS is refused when the command starts only by UEFI.
boot=$(INSTALLER_CONF="${tmp}/dragonfly.conf" INSTALLER_INSTALL_COMMAND="${tmp}/uefi-only" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/three-disks.conf" \
	"${backend}" disk probe | python3 -I -B -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import diskplan
d = json.load(sys.stdin)["detail"]
p = {"version": 1, "mode": "erase", "disks": [d["disks"][0]["name"]], "layout": "single",
     "filesystem": "hammer2", "boot": "bios"}
e = diskplan.validate(p, d, "dragonfly")
print(diskplan.system("dragonfly", d)["boot"], any("boot mode" in x for x in e))' "${root}/lib")
check "uefi only: the system offers UEFI, a BIOS plan is refused" "('uefi',) True" "${boot}"

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 59) % 400) + 2300 ))
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

cat > "${tmp}/boot.json" <<'JSON'
[{"name": "boot", "page": "disk", "full": false,
  "state": {"mode": "erase", "usage": "together", "advanced": true, "report": "boot"}}]
JSON
# render <name> <conf> <install command>
render() {
	mkdir -p "${tmp}/$1"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="${tmp}/$2.conf" INSTALLER_INSTALL_COMMAND="$3" \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/three-disks.conf" \
		bin/installer-gui --render "${tmp}/boot.json" --size 1024x768 --screenshots "${tmp}/$1" \
		> "${tmp}/$1.log" 2>&1 || cat "${tmp}/$1.log" >&2
}
r() { # r <dir> <python expression of the report r>
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/$1/boot.boot.json" "$2" 2>&1
}
render uefi dragonfly "${tmp}/uefi-only"
check "uefi only: the Disk page offers UEFI alone" "['uefi'] uefi" "$(r uefi 'str(r["offered"]) + " " + str(r["active"])')"
check "uefi only: shown as a text, not a drop-down" "False UEFI" "$(r uefi 'str(r["dropdown"]) + " " + r["fixed"]')"
check "uefi only: the plan starts by UEFI" uefi "$(r uefi 'r["plan"]')"
render both openbsd "${tmp}/old"
check "both ways: a drop-down of UEFI and BIOS" "['uefi', 'bios'] True" \
	"$(r both 'str(r["offered"]) + " " + str(r["dropdown"])')"

finish

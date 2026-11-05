#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The illumos adapter on the outputs of OpenIndiana 2026.10: its disk
# names, the disks it offers (never the medium or the pool of the root),
# its hardware, its hash scheme, its zone table, its layouts (the same as
# the install command's --capabilities and lib/diskplan.py), and the Disk
# page: the disks together only (no question), the home directories and
# the data encrypted (its own box), the system itself not.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-illumos.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
backend="${root}/bin/installer-backend"
conf="${root}/tests/fixtures/installer-illumos.conf"
fixture="${root}/tests/fixtures/disks/captured-illumos.conf"

# Disk names.
. "${root}/lib/backend.sh"
names=''
for n in c2t0d0 c0t5000CCA012345678d0 ada0 c2t0d0s1 '../c2t0d0' "$(printf 'c2t0d0\nx')" C2t0d0; do
	if disk_name_valid "${n}"; then names="${names} yes"; else names="${names} no"; fi
done
check "disk names: cXtYdZ and BSD names, never a slice, a path or two lines" \
	" yes yes yes no no no no" "${names}"

# The adapter runs outside a rehearsal: no gap reported.
out=$(INSTALLER_CONF="${conf}" INSTALLER_POLICY_CONF="${root}/tests/fixtures/illumos/policy.conf" \
	adapters/illumos.sh hash-scheme 2>&1) || :
check "the hash scheme of the captured policy.conf" sha512 "${out}"

# The disks: the pool of the root is never offered; the rest is read from
# the captured outputs.
out=$(INSTALLER_CONF="${conf}" INSTALLER_ADAPTER_FIXTURE="${fixture}" \
	INSTALLER_MNTTAB="${root}/tests/fixtures/illumos/mnttab-installed" \
	"${backend}" disk probe 2>&1)
got=$(printf '%s' "${out}" | python3 -I -B -c '
import json, sys
r = json.load(sys.stdin)
d = r["detail"]["disks"]
print(" ".join(x["name"] for x in r["disks"]), "|",
      " ".join("%s:%s:%s" % (x["name"], x["serial"], x["size_bytes"]) for x in d))' 2>&1) || :
check "illumos: the disk of the pool of the root is not offered, the other is read" \
	"c4t0d0 | c4t0d0:BHYVE-0000-0000-0002:21474836480" "${got}"
# A live system started from a USB stick (c4t0d0 here): the root is a
# ramdisk, the medium is on /.cdrom.
sed 's|/dev/dsk/c1t0d0s2|/dev/dsk/c4t0d0p1:1|' tests/fixtures/illumos/mnttab-live > "${tmp}/mnttab-usb"
out=$(INSTALLER_CONF="${conf}" INSTALLER_ADAPTER_FIXTURE="${fixture}" \
	INSTALLER_MNTTAB="${tmp}/mnttab-usb" \
	"${backend}" disk probe 2>&1)
got=$(printf '%s' "${out}" | python3 -I -B -c '
import json, sys; print(" ".join(x["name"] for x in json.load(sys.stdin)["disks"]))' 2>&1) || :
check "illumos live: the medium is not offered; a pool the root is not in is" "c2t0d0" "${got}"

# Fail closed: a ZFS root whose disks cannot be read (zpool status fails,
# or names no disk of the pool) refuses the disk section; nothing is
# offered for erasing.
for kind in fails nomembers; do
	cp -R tests/fixtures/captures/illumos/live-host "${tmp}/cap-${kind}"
	case "${kind}" in
		fails) echo 1 > "${tmp}/cap-${kind}/zpool_status.rc"; : > "${tmp}/cap-${kind}/zpool_status.out" ;;
		nomembers) printf '  pool: rpool\n state: ONLINE\nconfig:\n\n\tNAME STATE\n\trpool ONLINE\n' \
			> "${tmp}/cap-${kind}/zpool_status.out" ;;
	esac
	# A rehearsal refuses only with EXCLUSION=strict (cannot_tell).
	sed "s|^DISKS_CAPTURE=.*|DISKS_CAPTURE=${tmp}/cap-${kind}|" "${fixture}" > "${tmp}/${kind}.conf"
	printf 'EXCLUSION=strict\n' >> "${tmp}/${kind}.conf"
	cp tests/fixtures/disks/captured-illumos-sniffs.json "${tmp}/"
	rc=0
	out=$(INSTALLER_CONF="${conf}" INSTALLER_ADAPTER_FIXTURE="${tmp}/${kind}.conf" \
		INSTALLER_MNTTAB="${root}/tests/fixtures/illumos/mnttab-installed" \
		"${backend}" disk probe 2>&1) || rc=$?
	check "zpool status ${kind}: the disk section is refused (exit 3), no disk offered" \
		"3 yes no" "${rc} $(case "${out}" in *"cannot list disks: "*) echo yes ;; *) echo no ;; esac) $(case "${out}" in *'"disks":[{'*) echo yes ;; *) echo no ;; esac)"
done

# The same rehearsal without EXCLUSION=strict only says what it cannot
# tell (the rule of cannot_tell, the same for every system).
sed "s|^DISKS_CAPTURE=.*|DISKS_CAPTURE=${tmp}/cap-fails|" "${fixture}" > "${tmp}/lenient.conf"
rc=0
out=$(INSTALLER_CONF="${conf}" INSTALLER_ADAPTER_FIXTURE="${tmp}/lenient.conf" \
	INSTALLER_MNTTAB="${root}/tests/fixtures/illumos/mnttab-installed" \
	"${backend}" disk probe 2>&1) || rc=$?
check "a rehearsal (not strict) that cannot tell: it says so and goes on" "0 yes" \
	"${rc} $(case "${out}" in *"cannot list disks: zpool status failed (exit 1)"*) echo yes ;; *) echo no ;; esac)"

# The hardware of the captured outputs.
out=$(INSTALLER_CONF="${conf}" INSTALLER_ADAPTER_FIXTURE="${fixture}" adapters/illumos.sh hardware)
check "illumos: the hardware of the captured outputs" "Ethernet:vioif GPU:vgatext Input:kb8042 Input:mouse8042" \
	"$(printf '%s' "${out}" | python3 -I -B -c '
import json, sys
print(" ".join(sorted(d["class"] + ":" + d["driver"] for d in json.load(sys.stdin)["devices"])))')"

# The zone table of illumos (tab/zone_sun.tab under its zoneinfo).
mkdir -p "${tmp}/zoneinfo/tab"
printf '#comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\nUS\t+404251-0740023\tAmerica/New_York\tEastern\n' \
	> "${tmp}/zoneinfo/tab/zone_sun.tab"
out=$(env -u INSTALLER_ADAPTER_FIXTURE INSTALLER_CONF="${conf}" INSTALLER_ZONEINFO="${tmp}/zoneinfo" \
	adapters/illumos.sh timezones | cut -f1 | tr '\n' ' ')
check "illumos: the zones of tab/zone_sun.tab" "UTC America/New_York Europe/Berlin " "${out}"
check_contains "illumos: the zoneinfo of illumos" "/usr/share/lib/zoneinfo" "$(cat adapters/illumos.sh)"

# kbd -s is never run: without a terminal it asks again forever.
check "kbd -s is never run" "" \
	"$(grep -rnE 'kbd[[:space:]]+-s' adapters lib bin sections.d | grep -vE ':[0-9]+:[[:space:]]*#' || true)"

# The layouts: the adapter's, the install command's and lib/diskplan.py's
# agree.
got=$(INSTALLER_CONF="${conf}" env -u INSTALLER_ADAPTER_FIXTURE adapters/illumos.sh layouts | python3 -I -B -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import diskplan
mine = json.load(sys.stdin)
theirs = json.load(open(sys.argv[2]))
table = diskplan.system("illumos")
given = diskplan.system("illumos", {"disks": [], "capabilities": theirs})
same = all(table[k] == given[k] or tuple(table[k]) == tuple(given[k]) for k in
           ("layouts", "filesystems", "modes", "data_pools", "boot", "encryption", "home_encryption", "swap_encryption",
            "usages", "not_offered"))
print(mine == theirs, same)' "${root}/lib" "${root}/tests/fixtures/illumos/capabilities.json")
check "illumos: os_layouts is the install command's answer, and lib/diskplan.py agrees" "True True" "${got}"

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 67) % 400) + 3100 ))
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

# The shot names nda0, a disk of the sample report: an illumos picture
# shows an illumos disk in its place.
printf '%s\n' '[{"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "report": "usage"}}]' \
	> "${tmp}/usage.json"
# render <name> <conf> <disk fixture> — the Disk page (no exclusion).
render() {
	mkdir -p "${tmp}/$1"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_CONF="$2" INSTALLER_MNTTAB=/nonexistent \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/$3" \
		bin/installer-gui --render "${tmp}/usage.json" --size 1024x768 --screenshots "${tmp}/$1" \
		> "${tmp}/$1.log" 2>&1 || cat "${tmp}/$1.log" >&2
}
r() {
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/$1/disk.usage.json" "$2" 2>&1
}
# The disks of an illumos picture are those of tools/render-fixtures (the
# pictures of the documentation are drawn with it): illumos disks.
ill_fixture=$(sed -n 's/^illumos=\([^ ]*\).*/\1/p' tools/render-fixtures 2>/dev/null) || ill_fixture=three-disks.conf
check "the pictures of illumos are drawn with the captured illumos disks" captured-illumos.conf "${ill_fixture}"
check_contains "tools/render-screenshots.sh draws with the disks of the system" \
	'INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/${fixture}"' "$(cat tools/render-screenshots.sh)"
render illumos "${conf}" "${ill_fixture}"
check "an illumos picture lists illumos disks only (no ada, da, nda)" "['c2t0d0', 'c4t0d0']" \
	"$(r illumos '[d for d in r["disks"]] if all(__import__("re").fullmatch(r"c\d+(t[0-9A-F]+)?d\d+", d) for d in r["disks"]) else r["disks"]')"
check "illumos: the disk of the shot (nda0) is an illumos disk in the plan" "['c2t0d0']" \
	"$(r illumos 'r["selected"]')"
check "illumos: no together-or-separately question (together only)" "False" "$(r illumos 'r["asked"]')"
check "illumos: the separate card is hidden" "{'together': True, 'separate': False}" "$(r illumos 'r["shown"]')"
check "illumos: the box encrypts the home directories and the data" \
	"Encrypt the home directories and the data (ZFS native); the passphrase is asked at every start" \
	"$(r illumos 'r["enc_label"]')"
check "illumos: no line about what is not offered or not encrypted" "" "$(r illumos 'r["enc_note"]')"
check "illumos: the passphrase is asked for" True "$(r illumos 'r["passphrase_shown"]')"
check "illumos: no Encrypt the swap (its install command refuses it)" False "$(r illumos 'r["swap_enc_shown"]')"
# The Before and after box at 1024x768: every "after" bar shows whole,
# inside its box and inside the page (the page scrolls to it).
printf '%s\n' '[{"name": "bars", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "report": "bars"}}]' \
	> "${tmp}/bars.json"
mkdir -p "${tmp}/bars"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${conf}" INSTALLER_MNTTAB=/nonexistent \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/${ill_fixture}" \
	bin/installer-gui --render "${tmp}/bars.json" --size 1024x768 --screenshots "${tmp}/bars" \
	> "${tmp}/bars.log" 2>&1 || cat "${tmp}/bars.log" >&2
check "1024x768: the after bar shows whole, in its box and on the screen as the page opens" "1 True True True" \
	"$(python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1]))
ok = [all(b[k] for b in r) for k in ("inside_box", "inside_page", "inside_view")]
print(len(r), *ok, r if not all(ok) else "")' \
	"${tmp}/bars/bars.bars.json" 2>&1 | sed 's/ *$//')"
# The Disk page when the disks cannot be told: the reason and what to do,
# where the list would be; Next is refused with the reason.
printf '%s\n' '[{"name": "refused", "page": "disk", "full": false, "state": {"mode": "erase", "report": "probe", "press_next": true, "look_again": true}}]' \
	> "${tmp}/refused.json"
mkdir -p "${tmp}/refused"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${conf}" INSTALLER_MNTTAB="${root}/tests/fixtures/illumos/mnttab-installed" \
	INSTALLER_ADAPTER_FIXTURE="${tmp}/fails.conf" \
	bin/installer-gui --render "${tmp}/refused.json" --size 1024x768 --screenshots "${tmp}/refused" \
	> "${tmp}/refused.log" 2>&1 || cat "${tmp}/refused.log" >&2
p() {
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/refused/refused.probe.json" "$1" 2>&1
}
check "refused disks: one message where the list would be (heading, reason, next step)" \
	"['No disk can be offered', 'zpool status failed.', 'Check the disk tools, then Look for disks again.']" \
	"$(p 'r["lines"]')"
check "refused disks: only the message and Look for disks again are shown" \
	"{'list': False, 'usage': False, 'layout': False, 'before_after': False, 'health': False, 'secure_erase': False, 'look_again': True}" \
	"$(p 'r["shown"]')"
check "refused disks: no other problem lines" "" "$(p 'r["problems"]')"
check "refused disks: Look for disks again reads the disks anew" True "$(p 'r["reread"]')"
check "refused disks: Next says why" \
	"No disk can be offered: zpool status failed." "$(p 'r["error"]')"
sed 's/^OS=.*/OS=freebsd/' "${conf}" > "${tmp}/freebsd.conf"
render freebsd "${tmp}/freebsd.conf" three-disks.conf
check "FreeBSD (no usages): both cards, the question asked" "True {'together': True, 'separate': True}" \
	"$(r freebsd 'str(r["asked"]) + " " + str(r["shown"])')"
check "FreeBSD (no swap_encryption): Encrypt the swap is offered" True "$(r freebsd 'r["swap_enc_shown"]')"

finish

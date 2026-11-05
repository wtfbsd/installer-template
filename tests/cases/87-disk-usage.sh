#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The question "together or separately" of the Disk page (two disks or
# more): what the cards show is what the model holds.  No card looks chosen
# before one is; choosing one clears the message that asked for it; and
# "separately" is offered wherever the system can install it.  On OpenBSD
# (its install command makes an FFS data disk of a plan's data[]), the
# separate card is not greyed.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-usage.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# The model: OpenBSD offers data disks (the adapter's layouts verb).
sed 's/^OS=.*/OS=openbsd/' installer.conf > "${tmp}/openbsd.conf"
caps=$(INSTALLER_CONF="${tmp}/openbsd.conf" INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
	bin/installer-apply --list disks | python3 -I -B -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import diskplan
detail = json.load(sys.stdin)["detail"]
print(diskplan.data_pools_offered("openbsd", detail))' "${root}/lib")
check "OpenBSD offers disks of their own (data disks)" True "${caps}"

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -B -c 'import gi' 2>/dev/null; then
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 47) % 400) + 1900 ))
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

cat > "${tmp}/usage.json" <<'JSON'
[{"name": "fresh", "page": "disk", "full": false, "state": {"mode": "erase", "report": "usage"}},
 {"name": "next-then-together", "page": "disk", "full": false,
  "state": {"mode": "erase", "report": "usage", "press_next": true, "choose": "together"}},
 {"name": "separate", "page": "disk", "full": false,
  "state": {"mode": "erase", "report": "usage", "choose": "separate"}}]
JSON
rm -rf "${tmp}/shots" && mkdir "${tmp}/shots"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_IDENTITY="${root}/tests/fixtures/identity-default" INSTALLER_CONF="${tmp}/openbsd.conf" INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
	bin/installer-gui --render "${tmp}/usage.json" --size 1024x768 --screenshots "${tmp}/shots" \
	> "${tmp}/render.log" 2>&1 || cat "${tmp}/render.log" >&2
r() { # r <shot> <python expression of the report r>
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/shots/$1.usage.json" "$2" 2>&1
}
# The default way (together) is chosen, in the model and on the card, so
# the page shows the disks at once; no other card looks chosen.
check "fresh: the model holds the default, together" together "$(r fresh 'r["model"]')"
check "fresh: the together card shows it, the other does not" "True False" "$(r fresh 'str(r["active"]["together"]) + " " + str(r["active"]["separate"])')"
check "fresh: the list of the disks is shown at once" True "$(r fresh 'r["list_shown"]')"
check "fresh: Next is not refused for a choice to make" "" \
	"$(r fresh '"x" if any("together or separately" in p for p in r["problems"]) else ""')"
check "fresh: separately can be chosen on OpenBSD" True "$(r fresh 'r["sensitive"]["separate"]')"
check "Next first, then together: the model holds together" together "$(r next-then-together 'r["model"]')"
check "Next first, then together: the card shows it" True "$(r next-then-together 'r["active"]["together"]')"
check "Next first, then together: the message asking for a choice is gone" "" \
	"$(r next-then-together 'r["error"] if "together or separately" in r["error"] else ""')"
check "an OpenBSD picture names OpenBSD 8.0, not the BASE of the sample identity" \
	"OpenBSD 8.0 False" "$(r fresh '("OpenBSD 8.0" if "OpenBSD 8.0" in r["identity"] else r["identity"]) + " " + str("FreeBSD" in r["identity"])')"
check "separate: the model holds separate" separate "$(r separate 'r["model"]')"
check "separate: no layout note (the system takes one disk)" False "$(r separate 'r["layout_note"]')"

# OpenBSD offers Erase and install only: no Installation type page (Next
# on the time zone leads to the Disk page, the step is not listed), and
# no page says what is not offered.
cat > "${tmp}/flow.json" <<'JSON'
[{"name": "tz", "page": "timezone", "full": false, "state": {"report": "page", "press_next": true}},
 {"name": "disk", "page": "disk", "full": false, "state": {"mode": "erase", "report": "page"}}]
JSON
mkdir -p "${tmp}/flow"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${tmp}/openbsd.conf" INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
	bin/installer-gui --render "${tmp}/flow.json" --size 1024x768 --screenshots "${tmp}/flow" \
	> "${tmp}/flow.log" 2>&1 || cat "${tmp}/flow.log" >&2
f() {
	python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
		"${tmp}/flow/$1.page.json" "$2" 2>&1
}
check "OpenBSD: Next on the time zone leads to the Disk page" disk "$(f tz 'r["page"]')"
check "OpenBSD: Installation type is not a step" False "$(f tz '"type" in r["steps"]')"
check "OpenBSD: no line about what is not offered on the Disk page" "[]" "$(f disk 'r["not_offered"]')"

# An install command that takes Erase and Manual: the page is there, with
# those two cards only and no line about the third.
cat > "${tmp}/two-modes" <<'SH'
#!/bin/sh
[ "${1-}" = --capabilities ] || exit 64
echo '{"modes": ["erase", "manual"], "layouts": [{"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1}]}'
SH
chmod 755 "${tmp}/two-modes"
printf '%s\n' '[{"name": "typecards", "page": "type", "full": false, "state": {"report": "page"}}]' > "${tmp}/type.json"
GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
	INSTALLER_CONF="${tmp}/openbsd.conf" INSTALLER_INSTALL_COMMAND="${tmp}/two-modes" \
	INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
	bin/installer-gui --render "${tmp}/type.json" --size 1024x768 --screenshots "${tmp}/flow" \
	> "${tmp}/flow2.log" 2>&1 || cat "${tmp}/flow2.log" >&2
check "two modes: only their cards are shown" "{'erase': True, 'alongside': False, 'manual': True}" \
	"$(f typecards 'r["type_cards"]')"
check "two modes: no line about what is not offered" "[]" "$(f typecards 'r["not_offered"]')"

finish

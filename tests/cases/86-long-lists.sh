#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Every list that can grow long scrolls in a window of its own, so the page
# stays on the screen and the control after the list (the Wi-Fi passphrase,
# the button that adds a partition, the mount point of the data disks, the
# confirmation of the summary) stays in sight at 1024x768.
#
# 1. Every page: every list-like widget (TreeView, ListBox, FlowBox, a box
#    marked as a list) is inside a scroller of its own, not only the page's;
#    the marked exceptions say why.
# 2. Long lists: 120 Wi-Fi networks, 80 hardware rows, 40 partitions, 15
#    data disks, a summary of 16 disks: each list is capped, the page stays
#    short, the control after it is inside the window.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-lists.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

if ! command -v broadwayd >/dev/null 2>&1 || ! python3 -I -c 'import gi' 2>/dev/null; then
	printf 'skip: no broadwayd or PyGObject\n'
	finish
	exit 0
fi
ready=no
for try in 1 2 3 4 5 6; do
	n=$(( ( ($$ + try * 43) % 400) + 1500 ))
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

render() { # render <fixture> <spec> <dir>
	rm -rf "$3" && mkdir "$3"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="$1" \
		bin/installer-gui --render "$2" --size 1024x768 --screenshots "$3" > "${tmp}/render.log" 2>&1 ||
		cat "${tmp}/render.log" >&2
}

# 1. Every page of the usual machine.
python3 -I - "${tmp}/pages.json" <<'PY'
import json, sys
pages = [("welcome", {}), ("keyboard", {}), ("timezone", {}), ("type", {"mode": "erase"}),
         ("disk", {"mode": "erase", "selected": ["nda0"], "usage": "together"}),
         ("disk", {"mode": "manual"}), ("users", {}), ("network", {}), ("software", {}),
         ("hardware", {})]
spec = [{"name": f"p{i:02d}-{p}", "page": p, "full": False,
         "state": dict(s, report="lists"), "disk_state": s if p == "disk" else None}
        for i, (p, s) in enumerate(pages)]
for item in spec:
    if item["disk_state"] is None:
        del item["disk_state"]
spec.append({"name": "p99-summary", "page": "summary", "full": False, "state": {"report": "lists"},
             "disk_state": {"mode": "erase", "selected": ["nda0"], "usage": "together"}})
json.dump(spec, open(sys.argv[1], "w"))
PY
render "${root}/tests/fixtures/disks/dual-os.conf" "${tmp}/pages.json" "${tmp}/pages"
out=$(python3 -I - "${tmp}/pages" <<'PY'
import glob, json, sys
problems, pages, exceptions = [], 0, 0
for path in sorted(glob.glob(sys.argv[1] + "/*.lists.json")):
    report = json.load(open(path))
    pages += 1
    exceptions += len(report["exceptions"])
    for exc in report["exceptions"]:
        if not exc["reason"]:
            problems.append(f"{report['page']}: an exception without a reason")
    for item in report["lists"]:
        if not item["own_scroller"]:
            problems.append(f"{report['page']}: a {item['kind']} scrolls only with the page")
    # The page itself is at most one and a half screens high: whatever is
    # on it is reached with at most one scroll; the buttons never scroll.
    if report["page_height"] > 1.5 * report["viewport"]:
        problems.append(f"{report['page']} is {report['page_height']} high, the screen {report['viewport']}")
print(f"{pages} pages; " + ("; ".join(problems) or "every list scrolls by itself"))
PY
)
check "every list of every page scrolls by itself" "11 pages; every list scrolls by itself" "${out}"

# 2. Long lists.
python3 -I - "${tmp}" "${root}" <<'PY'
import json, os, sys
tmp, root = sys.argv[1], sys.argv[2]
disks = [{"name": f"ada{i}", "model": f"Example Disk {i}", "size_bytes": 100 * 1024 ** 3,
          "serial": f"EX{i:04d}", "bus": "SATA", "ssd": True,
          "health": {"status": "ok", "summary": "healthy"}, "scheme": "none",
          "partitions": [], "os": [], "free": [{"start_mb": 1, "size_mb": 100 * 1024 - 2}]}
         for i in range(16)]
json.dump({"boot_mode": "uefi", "ram_mb": 8192, "disks": disks}, open(f"{tmp}/many.json", "w"))
json.dump({"devices": [{"class": "Input", "name": f"Example device {i}", "driver": f"hms{i}",
                        "firmware": "not needed", "status": "working"} for i in range(80)]},
          open(f"{tmp}/hw.json", "w"))
scan = ",".join(f"Example net {i}|wpa2|{90 - i % 80}" for i in range(120))
with open(f"{tmp}/long.conf", "w") as conf:
    conf.write("DISKS=" + ",".join(f"ada{i}|Example Disk {i}|{100 * 1024 ** 3}" for i in range(16)) + "\n")
    conf.write(f"DISKS_DETAIL={tmp}/many.json\nINTERFACES=iwm0|Example Wireless\n")
    conf.write(f"WIFI_SCAN={scan}\nONLINE=yes\nHARDWARE={tmp}/hw.json\n")
parts = [{"disk": "ada0", "type": "efi", "size_mb": 260, "mount": "/boot/efi"},
         {"disk": "ada0", "type": "root", "size_mb": 20480, "mount": "/"}]
parts += [{"disk": "ada1", "type": "data", "size_mb": 1024, "mount": f"/d{i}"} for i in range(38)]
spec = [
    {"name": "wifi", "page": "network", "full": False, "state": {"report": "lists"}},
    {"name": "hardware", "page": "hardware", "full": False, "state": {"report": "lists"}},
    {"name": "partitions", "page": "disk", "full": False,
     "state": {"mode": "manual", "partitions": parts, "report": "lists"}},
    {"name": "datadisks", "page": "disk", "full": False,
     "state": {"mode": "erase", "selected": ["ada0", "ada1"], "usage": "together",
               "data_disks": [f"ada{i}" for i in range(2, 16)], "report": "lists"}},
    {"name": "separate", "page": "disk", "full": False,
     "state": {"mode": "erase", "selected": ["ada0"], "usage": "separate",
               "separate": {f"ada{i}": None for i in range(1, 16)}, "report": "lists"}},
    {"name": "summary16", "page": "summary", "full": False, "state": {"report": "lists"},
     "disk_state": {"mode": "erase", "selected": [f"ada{i}" for i in range(16)], "usage": "together",
                    "layout": "raidz2"}},
]
json.dump(spec, open(f"{tmp}/long.json", "w"))
PY
render "${tmp}/long.conf" "${tmp}/long.json" "${tmp}/long"
for pair in wifi:wifi hardware:hardware partitions:partitions datadisks:data-disks \
	separate:other-disks summary16:summary-disks; do
	name=${pair%%:*}
	out=$(python3 -I - "${tmp}/long/${name}.lists.json" "${pair#*:}" <<'PY' 2>&1
import json, sys
r = json.load(open(sys.argv[1]))
problems = []
if not r["lists"]:
    problems.append("no list")
# At most one and a half screens; two (one scroll) where the person opened
# the folded choices (the data disks are in Advanced).
limit = 2.0 if sys.argv[2] == "data-disks" else 1.5
if r["page_height"] > limit * r["viewport"]:
    problems.append(f"the page is {r['page_height']} high, the screen {r['viewport']} "
                    f"(lists: {[(i.get('name'), i['height']) for i in r['lists']]})")
for item in r["lists"]:
    if not item["own_scroller"]:
        problems.append(f"a {item['kind']} scrolls with the page")
    elif item["max"] <= 0 or item["height"] > item["max"] + 8:
        problems.append(f"a {item['kind']} is {item['height']} high, over {item['max']}")
# The list of the case and the control after it fit on the screen
# together: whoever sees the list sees what follows it without scrolling
# the page, and the list itself never grows past its cap.
target = [i for i in r["lists"] if i.get("name") == sys.argv[2]]
if not target:
    problems.append(f"no list {sys.argv[2]}")
else:
    item = target[0]
    if "follower_bottom" not in item:
        problems.append("nothing follows the list")
    elif sys.argv[2] in ("wifi", "hardware") and item["follower_bottom"] > r["viewport"]:
        # Pages without much above the list: on the screen as they open.
        problems.append(f"the {item['follower']} after the list is off the screen "
                        f"({item['follower_bottom']} > {r['viewport']})")
    elif item["follower_bottom"] - item["top"] > r["viewport"]:
        problems.append(f"the list and the {item['follower']} after it do not fit on the screen "
                        f"({item['follower_bottom'] - item['top']} > {r['viewport']})")
print("; ".join(problems) or "capped")
PY
)
	check "${name}: the long list is capped and what follows it is in sight" capped "${out}"
done

finish

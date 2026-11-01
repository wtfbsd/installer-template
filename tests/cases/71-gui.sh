#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The graphical front end, drawn for real.
#
# It runs on an X server from Xvfb when Xvfb is installed, else on the
# Broadway backend of GTK (broadwayd) when that is installed; with neither,
# the drawing checks are skipped and the case says so.  The checks that need
# no display (no GTK display: the text front end in a terminal) always run.
#
# The smoke run fills the fields and clicks the buttons of every page, the
# way a person does, installs with the rehearsal, and writes a picture and
# the place of the buttons and of the title of every page.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-gui.XXXXXX")
tmp_root=$(dirname "${tmp}")
server_pid=''
stop_server() {
	[ -z "${server_pid}" ] || kill "${server_pid}" 2>/dev/null || :
	rmrf "${tmp}" "${tmp_root}" || :
}
trap 'stop_server' EXIT INT TERM HUP

gui="${root}/bin/installer-gui"
fixtures="${root}/tests/fixtures"
mkdir -p "${tmp}/mounts-dir"
printf '/dev/ada9p3 / ufs rw 0 0\n' > "${tmp}/mounts"

# ------------------------------------------------- without a display
python3 -I -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null && have_gi=yes || have_gi=no

rc=0
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 "${gui}" --check >/dev/null 2>&1 || rc=$?
check_rc "--check says that GTK cannot start without a display" 3 "${rc}"

# No display and no terminal: the reason is given and nothing hangs.
rc=0
out=$(env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 "${gui}" < /dev/null 2>&1) || rc=$?
check_rc "without a display and a terminal the installer stops with 3" 3 "${rc}"
check_contains "it says that it falls back to the text front end" \
	"using the text front end" "${out}"

# A display GTK cannot open, and a terminal program: the text front end runs
# in the terminal and its exit code is the exit code of the installer.
fake="${tmp}/fakebin"
mkdir -p "${fake}"
cat > "${fake}/xterm" <<'XTERM'
#!/bin/sh
printf '%s\n' "$*" > "${XTERM_LOG}"
while [ $# -gt 0 ] && [ "$1" != -e ]; do shift; done
shift
exec "$@"
XTERM
chmod +x "${fake}/xterm"
rc=0
out=$(env -u WAYLAND_DISPLAY PATH="${fake}:${PATH}" DISPLAY=:97 GDK_BACKEND=x11 \
	XTERM_LOG="${tmp}/xterm.log" \
	BSDDIALOG="${fixtures}/fake-bsddialog" BSDDIALOG_LOG="${tmp}/bsd.log" \
	BSDDIALOG_STATE="${tmp}/bsd.state" BSDDIALOG_SCRIPT="${fixtures}/answers-happy.txt" \
	INSTALLER_STATE_PARENT="${tmp}" INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
	"${gui}" < /dev/null 2>&1) || rc=$?
check_rc "the text front end in xterm installs and its exit code is passed on" 0 "${rc}"
check_contains "xterm was started for the text front end" "installer-tui" \
	"$(cat "${tmp}/xterm.log" 2>/dev/null || true)"
check_contains "the text front end reached the finished page" "is installed" \
	"$(cat "${tmp}/bsd.log" 2>/dev/null || true)"

# The graphical front end never runs as root, and --smoke and --screenshots
# are refused for root.  The effective user is made 0 for the program by
# replacing os.geteuid before it runs: the check comes before GTK.
as_root_gui() {
	rc=0
	out=$(python3 -I -c '
import os, runpy, sys
os.geteuid = lambda: 0
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
' "${root}/lib/gui.py" "$@" 2>&1 < /dev/null) || rc=$?
}
as_root_gui --smoke "${tmp}/none.json" --screenshots /etc
check_rc "--smoke and --screenshots are refused for root" 2 "${rc}"
check_contains "the refusal says why" "refused for root" "${out}"
as_root_gui --windowed
check_rc "the graphical front end does not run as root" 3 "${rc}"
check_contains "it points root at the text front end" "installer-tui" "${out}"

# The smoke run never writes through a link or over a file.
python3 -I - "${root}/lib" "${tmp}" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import wizard
tmp = sys.argv[2]
target = os.path.join(tmp, "victim")
open(target, "w").write("keep")
os.symlink(target, os.path.join(tmp, "01-welcome.png"))
for name in ("01-welcome.png", "victim"):
    try:
        wizard.write_new_file(os.path.join(tmp, name), b"x")
        print("FAIL the smoke output was written over " + name)
    except OSError:
        print("ok   the smoke output is not written over " + name)
assert open(target).read() == "keep"
PY

# ------------------------------------------------- with a display
backend=''
if [ "${have_gi}" = no ]; then
	printf 'skip the drawing checks: GTK 3 for Python (gi) is not installed\n'
elif command -v Xvfb >/dev/null 2>&1; then
	backend=x11
	n=$(( ($$ % 400) + 100 ))
	Xvfb ":${n}" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
	server_pid=$!
	sleep 1
	set -- env DISPLAY=":${n}" GDK_BACKEND=x11
elif command -v broadwayd >/dev/null 2>&1; then
	backend=broadway
	# A display number that another program uses makes broadwayd stop:
	# try the next one until GTK can open the display.
	ready=no
	for try in 1 2 3 4 5 6; do
		n=$(( ( ($$ + try * 37) % 400) + 100 ))
		broadwayd ":${n}" >/dev/null 2>&1 &
		server_pid=$!
		for wait in 1 2 3 4 5 6 7 8 9 10; do
			if ! kill -0 "${server_pid}" 2>/dev/null; then
				break
			fi
			if BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway "${gui}" --check >/dev/null 2>&1; then
				ready=yes
				break
			fi
			sleep 0.5
		done
		[ "${ready}" = no ] || break
		kill "${server_pid}" 2>/dev/null || :
		server_pid=''
	done
	if [ "${ready}" = no ]; then
		backend=''
		check "broadwayd started" yes no
	fi
	set -- env BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway
else
	printf 'skip the drawing checks: neither Xvfb nor broadwayd is installed\n'
fi

if [ -n "${backend}" ]; then
	printf 'drawing on %s\n' "${backend}"
	mask=$(printf '%s.%s.%s.%s' 255 255 255 0)
	cat > "${tmp}/answers.json" <<JSON
{"keymap": "de", "timezone": "Europe/Berlin", "disk": "ada1", "user": "tester",
 "full_name": "Test User", "hostname": "box1", "network": "static", "net_if": "em0",
 "ipv4_addr": "192.0.2.10", "ipv4_mask": "${mask}", "ipv4_gw": "192.0.2.1"}
JSON
	mkdir -p "${tmp}/shots"
	rc=0
	out=$(printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" \
		PATH="${root}/tests/stubs:${PATH}" STUB_SETXKBMAP_LOG="${tmp}/setxkbmap.log" \
		INSTALLER_REHEARSAL_STEP_SECONDS=1 INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		timeout 120 "${gui}" --smoke "${tmp}/answers.json" --screenshots "${tmp}/shots" 2>&1) || rc=$?
	check_rc "the smoke run installs" 0 "${rc}"
	check_contains "the smoke run saw every page in order" \
		"smoke: pages welcome keyboard timezone type disk users network software summary install finish" "${out}"
	check "picking a keymap applies it to the live X session" "de" \
		"$(tail -n 1 "${tmp}/setxkbmap.log" 2>/dev/null || true)"
	check_absent "no password in the log of the run" "s3cret-pass" \
		"$(cat "${tmp}/wtfbsd-installer.log" 2>/dev/null || true)"

	# Every picture is a drawn page, not an empty one.
	pictures=$(python3 -I - "${tmp}/shots" <<'PY'
import sys, glob, gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
bad = []
for path in sorted(glob.glob(sys.argv[1] + "/*.png")):
    pix = GdkPixbuf.Pixbuf.new_from_file(path)
    data = pix.get_pixels()
    step = pix.get_n_channels()
    colours = {bytes(data[i:i + 3]) for i in range(0, len(data) - 3, step * 97)}
    if len(colours) < 8:
        bad.append(path)
print(len(glob.glob(sys.argv[1] + "/*.png")), len(bad))
PY
)
	check "eleven drawn pages and no empty picture" "11 0" "${pictures}"

	# The one action cluster at the bottom right, the primary action on
	# the right and the default, and the title at the top left in a large
	# bold font.
	# layout_problems <layout.json> <width> <height> — what is wrong with
	# the pages of a smoke run drawn at that size.
	# fields_named <layout.json> — the labels of the text fields of the
	# users and the network page, sorted.
	fields_named() {
	python3 -I - "$1" <<'FIELDS'
import json, sys
seen = {}
for page in json.load(open(sys.argv[1])):
    if page["page"] in ("users", "network") and page["page"] not in seen:
        seen[page["page"]] = ", ".join(sorted(
            "/".join(field["labelled_by"]) or "(none)" for field in page.get("fields", [])))
print(" | ".join(f"{name}: {seen.get(name, '(not seen)')}" for name in ("users", "network")))
FIELDS
	}
	layout_problems() {
	python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys
problems = []
want_w, want_h = int(sys.argv[2]), int(sys.argv[3])
for page in json.load(open(sys.argv[1])):
    name, w, h = page["page"], page["width"], page["height"]
    if (w, h) != (want_w, want_h):
        problems.append(f"{name}: the window is {w}x{h}, not {want_w}x{want_h}")
    for b in page["buttons"]:
        if b["x"] < 0 or b["y"] < 0 or b["x"] + b["w"] > w or b["y"] + b["h"] > h:
            problems.append(f"{name}: the button {b['label']} is not inside the window")
        if "_" not in (b["label"] or ""):
            problems.append(f"{name}: the button {b['label']} has no mnemonic")
    buttons = page["buttons"]
    if not buttons:
        problems.append(f"{name}: no buttons")
        continue
    xs = [b["x"] for b in buttons]
    if xs != sorted(xs):
        problems.append(f"{name}: the buttons are not in one row from left to right")
    if len({b["y"] for b in buttons}) != 1:
        problems.append(f"{name}: the buttons are not in one row")
    last = buttons[-1]
    if not last["primary"] or not last["default"]:
        problems.append(f"{name}: the rightmost button is not the primary default")
    if any(b["default"] for b in buttons[:-1]):
        problems.append(f"{name}: a second action is the default")
    if last["x"] + last["w"] < w - 40:
        problems.append(f"{name}: the cluster is not at the right edge")
    if last["y"] + last["h"] < h - 40:
        problems.append(f"{name}: the cluster is not at the bottom")
    if buttons[0]["x"] < w / 2:
        problems.append(f"{name}: the cluster reaches into the left half")
    t = page["title"]
    if t["y"] > 80 or t["x"] > 320:
        problems.append(f"{name}: the title is not at the top left of the page")
    if t["font_px"] < 18 or not t["bold"]:
        problems.append(f"{name}: the title is not large and bold")
    # Every text field of the pages of the form is labelled by its label:
    # a screen reader names the field when it has the focus.
    if name in ("users", "network"):
        fields = page.get("fields", [])
        if not fields:
            problems.append(f"{name}: no text field was found")
        for field in fields:
            if not [text for text in field["labelled_by"] if text]:
                problems.append(f"{name}: a {field['kind']} is not labelled by a label")
print("; ".join(problems) or "ok")
PY
	}
	layout=$(layout_problems "${tmp}/shots/layout.json" 1024 768)
	check "1024x768: every page fits, the buttons and the title are where the rules put them" "ok" "${layout}"
	# The names a screen reader says for the fields of the two pages.
	check "every text field of the users and network pages is labelled by its label" \
		"users: Confirm the password, Confirm the root password, Full name, Host name, Password, Root password, SSH public key, User name | network: IPv4 Address, IPv4 Address, IPv4 Gateway, IPv4 Gateway, IPv4 Netmask, IPv4 Netmask, IPv6 Address, IPv6 Address, IPv6 Gateway, IPv6 Gateway, IPv6 Prefix length, IPv6 Prefix length, Resolvers (DNS)" \
		"$(fields_named "${tmp}/shots/layout.json")"

	# The same at 1280x1024.
	mkdir -p "${tmp}/shots-1280"
	rc=0
	printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		timeout 120 "${gui}" --smoke "${tmp}/answers.json" --size 1280x1024 \
		--screenshots "${tmp}/shots-1280" > /dev/null 2>&1 || rc=$?
	check_rc "the smoke run installs at 1280x1024" 0 "${rc}"
	check "1280x1024: every page fits, the buttons and the title are where the rules put them" "ok" \
		"$(layout_problems "${tmp}/shots-1280/layout.json" 1280 1024)"

	# Large text (a screen with more dots per inch, or a larger font): the
	# content of a page is taller than the screen, scrolls, and the
	# buttons stay on the screen.
	mkdir -p "${tmp}/shots-large"
	rc=0
	printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" \
		INSTALLER_STATE_PARENT="${tmp}" INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		timeout 120 "${gui}" --smoke "${tmp}/answers.json" --size 1024x768 --text-scale 1.6 \
		--screenshots "${tmp}/shots-large" > /dev/null 2>&1 || rc=$?
	check_rc "the smoke run installs with large text" 0 "${rc}"
	check "large text at 1024x768: every page fits and the buttons are on the screen" "ok" \
		"$(layout_problems "${tmp}/shots-large/layout.json" 1024 768)"


	# Without a pointer: the keyboard alone (Tab, letters, Space, Alt and
	# the underlined letter) goes from Welcome to Installing.
	rc=0
	out=$(printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		timeout 120 "${gui}" --keyboard-walk "${tmp}/answers.json" 2>&1) || rc=$?
	check_rc "the keyboard alone installs" 0 "${rc}"
	check_contains "the keyboard alone goes through every page" \
		"keyboard: pages welcome keyboard timezone type disk users network software summary install" "${out}"
	# Alt and the letter work however the X server reports Alt: on the
	# letter (Mod1, or Meta), only by the Alt key before it, or released
	# first; every way advanced a page.
	check_contains "Alt and a letter work in every way a server sends them" "in 4 ways" "${out}"
	# A full name with a space, typed key by key, is kept whole.
	check_contains "a full name typed with a space is kept whole" \
		"keyboard: full name 'Test User'" "${out}"

	# A failed installation stays on the installing page.
	rc=0
	out=$(printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture-fail.conf" \
		timeout 120 "${gui}" --smoke "${tmp}/answers.json" 2>&1) || rc=$?
	check_rc "a failed installation ends the smoke run with 1" 1 "${rc}"
	check_contains "a failed installation never reaches the finished page" \
		"smoke: the installation failed" "${out}"

	# The installer that is ended by a signal removes the state of its run.
	mkdir -p "${tmp}/signal"
	"$@" INSTALLER_STATE_PARENT="${tmp}/signal" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		"${gui}" --windowed > /dev/null 2>&1 &
	gui_pid=$!
	sleep 3
	kill -TERM "${gui_pid}" 2>/dev/null || :
	rc=0
	wait "${gui_pid}" || rc=$?
	check_rc "a signal ends the graphical front end as a failed run" 1 "${rc}"
	check "the state of the run is gone after a signal" "" \
		"$(find "${tmp}/signal" -name 'wtfbsd-installer.*' -type d -print)"
	check "the log of the run is kept after a signal" yes \
		"$([ -f "${tmp}/signal/wtfbsd-installer.log" ] && echo yes || echo no)"

	# A name the system uses is refused on the users page.
	sed 's/"tester"/"root"/' "${tmp}/answers.json" > "${tmp}/root.json"
	rc=0
	out=$(printf 's3cret-pass\n' | "$@" STUB_MOUNTS="${tmp}/mounts" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
		timeout 120 "${gui}" --smoke "${tmp}/root.json" 2>&1) || rc=$?
	check_contains "the users page keeps a name the system uses back" \
		"smoke: users: Some fields need attention." "${out}"
fi

finish

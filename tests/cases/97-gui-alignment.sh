#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The alignment of the pages of the graphical front end.
#
# It draws every page (the pages of the documentation, tools/shots/docs.json)
# and checks the geometry of the pages that the alignment audit found
# wrong:
#
#   * a picture of a page has no transparent pixel;
#   * the fields of a form stand in one column;
#   * the box of a check button stands at the left edge of the widget;
#   * the cards of a flow box stand at the left edge of the page;
#   * a label of a message that has none takes no room;
#   * the values of the summary stand in one column a column of groups;
#   * the summary never says "on " without the name of the adapter;
#   * a form of fields does not grow past the width of a form;
#   * the controls of the network page stay on the screen;
#   * the strength of the password stands under the password;
#   * the buttons of the head of the table of the disks keep their height;
#   * the cards of the disk page have the same inset;
#   * a card of the installation type has no empty label;
#   * the badges of an item stand next to each other;
#   * the label of the public key stands at the top of its row;
#   * the plan of the disks does not touch the frame around it;
#   * the buttons of the action bar end where the page ends;
#   * the text of the welcome page stands at the top of the page.
#
# The harness that draws the pages and writes where every widget of them
# is lives in this case, not in the installer: the checks must fail when
# the pages are drawn the wrong way, not when the measuring is missing.
#
# It runs on an X server from Xvfb when Xvfb is installed, else on the
# Broadway backend of GTK (broadwayd) when that is installed; with
# neither, the drawing checks are skipped and the case says so.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-align.XXXXXX")
tmp_root=$(dirname "${tmp}")
server_pid=''
stop_server() {
	[ -z "${server_pid}" ] || kill "${server_pid}" 2>/dev/null || :
	rmrf "${tmp}" "${tmp_root}" || :
}
trap 'stop_server' EXIT INT TERM HUP

gui="${root}/bin/installer-gui"
fixtures="${root}/tests/fixtures"

python3 -I -B -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null && have_gi=yes || have_gi=no

# ------------------------------------------------- the harness
# The installer, drawn, with the place of every widget of the page
# written next to the picture of the page.
cat > "${tmp}/draw.py" <<'PY'
"""Draw the pages of the installer and write where every widget of the
page shown is: NAME.geometry.json next to NAME.png."""
import importlib.util
import json
import os
import sys

root = os.environ["REPO"]
lib = os.path.join(root, "lib")
sys.path.insert(0, lib)
sys.argv = [os.path.join(lib, "gui.py")] + sys.argv[1:]
spec = importlib.util.spec_from_file_location("gui", os.path.join(lib, "gui.py"))
gui = importlib.util.module_from_spec(spec)
sys.modules["gui"] = gui
spec.loader.exec_module(gui)
Gtk = gui.Gtk


def text_of(widget):
    """The text a widget shows, or None."""
    if isinstance(widget, Gtk.Label):
        return widget.get_text()
    if isinstance(widget, Gtk.Entry):
        return widget.get_text()
    if isinstance(widget, Gtk.Button):
        return widget.get_label() or ""
    return None


VALIGN = {Gtk.Align.FILL: "fill", Gtk.Align.START: "start", Gtk.Align.END: "end",
          Gtk.Align.CENTER: "center", Gtk.Align.BASELINE: "baseline"}


def geometry(win):
    """Where every widget of the page shown is."""
    top = win.offscreen or win
    out = []

    def walk(widget, path):
        if not widget.get_visible():
            return
        alloc = widget.get_allocation()
        xy = widget.translate_coordinates(top, 0, 0)
        ctx = widget.get_style_context()
        out.append({"type": type(widget).__name__,
                    "path": path,
                    "classes": ctx.list_classes(),
                    "x": xy[0] if xy else None, "y": xy[1] if xy else None,
                    "w": alloc.width, "h": alloc.height,
                    "valign": VALIGN.get(widget.get_valign()),
                    "mapped": widget.get_mapped(),
                    "text": text_of(widget)})
        if isinstance(widget, Gtk.Container):
            for index, child in enumerate(widget.get_children()):
                walk(child, f"{path}/{type(child).__name__}[{index}]")

    page = win.stack.get_visible_child()
    if page is not None:
        walk(page, "page")
    return out


def frame(win):
    """The frame around the page: the title, the scroller and the buttons."""
    top = win.offscreen or win
    tx, ty = win.title_label.translate_coordinates(top, 0, 0)
    sx, sy = win.page_scroller.translate_coordinates(top, 0, 0)
    alloc = win.page_scroller.get_allocation()
    buttons = []
    for child in win.actions_box.get_children():
        if not child.get_visible():
            continue
        cx, cy = child.translate_coordinates(top, 0, 0)
        box = child.get_allocation()
        buttons.append({"text": text_of(child), "x": cx, "y": cy,
                        "w": box.width, "h": box.height,
                        "valign": VALIGN.get(child.get_valign())})
    return {"title": {"x": tx, "y": ty, "w": win.title_label.get_allocation().width},
            "scroller": [sx, sy, alloc.width, alloc.height],
            "buttons": buttons}


original = gui.render_save


def hooked(win, outdir, name):
    gui.render_pump()
    data = {"page": win.page, "frame": frame(win),
            "widgets": geometry(win)}
    with open(os.path.join(outdir, name + ".geometry.json"), "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=1)
    return original(win, outdir, name)


gui.render_save = hooked
sys.exit(gui.main())
PY

# alignment <shots> — what is wrong with the geometry of the pages drawn
# in that directory; "ok" when nothing is wrong.
cat > "${tmp}/check.py" <<'PY'
"""The geometry of the pages: what is wrong with it."""
import glob
import json
import os
import sys

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf

shots = sys.argv[1]
FORM_WIDTH = 640          # the widest a form of fields is
problems = []
pages = {}
for path in sorted(glob.glob(os.path.join(shots, "*.geometry.json"))):
    data = json.load(open(path))
    pages.setdefault(data["page"], data)


def widgets(name):
    page = pages.get(name)
    if page is None:
        return []
    return [w for w in page.get("widgets", []) if w.get("mapped")]


def classes(widget):
    return set(widget.get("classes") or [])


def within(page, widget):
    """The widgets inside another one."""
    return [w for w in widgets(page["page"])
            if w["path"].startswith(widget["path"] + "/")]


def text_x(widget):
    """Where the text of a label starts."""
    return widget.get("text_x", widget["x"])


def painted_left(png, widget):
    """The leftmost pixel the widget paints, or None when it paints none."""
    pix = GdkPixbuf.Pixbuf.new_from_file(png)
    width, height = pix.get_width(), pix.get_height()
    step = pix.get_n_channels()
    data = pix.get_pixels()

    def pixel(x, y):
        offset = (y * width + x) * step
        return bytes(data[offset:offset + step])

    x, y = widget["x"], widget["y"]
    for row in range(y, min(y + widget["h"], height)):
        background = pixel(max(x - 6, 0), row)
        for col in range(max(x - 6, 0), min(x + 40, width)):
            if pixel(col, row) != background:
                return col
    return None


# A picture of a page has no transparent pixel: the page is painted on
# the background of the theme.
for png in sorted(glob.glob(os.path.join(shots, "*.png"))):
    pix = GdkPixbuf.Pixbuf.new_from_file(png)
    if not pix.get_has_alpha():
        continue
    data = pix.get_pixels()
    step = pix.get_n_channels()
    if any(data[i] == 0 for i in range(3, len(data), step)):
        problems.append(f"{os.path.basename(png)}: the picture has transparent pixels")

# The fields of the users page stand in one column.
entries = [w for w in widgets("users") if w["type"] == "Entry"]
if len(entries) > 1 and len({w["x"] for w in entries}) != 1:
    problems.append("users: the fields are not in one column: "
                    + str(sorted({w["x"] for w in entries})))

# The fields of the network page stand in one column.
fields = [w for w in widgets("network")
          if w["type"] in ("Entry", "ComboBoxText") and w["x"] > 300]
if len(fields) > 1 and len({w["x"] for w in fields}) != 1:
    problems.append("network: the fields are not in one column: "
                    + str(sorted({w["x"] for w in fields})))

# The box of a check button with a label is drawn at the left edge of the
# widget, like the box of one without a label.
checks = [w for w in widgets("software") if w["type"] == "CheckButton"]
with_label = [w for w in checks if w.get("text")]
without_label = [w for w in checks if not w.get("text")]
pictures = glob.glob(os.path.join(shots, "*-software.png"))
if with_label and without_label and pictures:
    left = painted_left(pictures[0], with_label[0])
    right = painted_left(pictures[0], without_label[0])
    if left != right:
        problems.append(f"software: the box of the check button with a label is at {left}, "
                        f"the one without a label at {right}")

# The cards of a flow box stand at the left edge of the page: what is in
# a child of a flow box starts where the child starts.
for name, page in pages.items():
    ws = widgets(name)
    for widget in ws:
        if widget["type"] != "FlowBoxChild":
            continue
        inside = [w["x"] for w in ws
                  if w["path"].startswith(widget["path"] + "/") and w["x"] is not None]
        if inside and min(inside) != widget["x"]:
            problems.append(f"{name}: what is in a card of a flow box starts at "
                            f"{min(inside)}, the card at {widget['x']}")

# A label of a message that has none takes no room.
for name, page in pages.items():
    for widget in widgets(name):
        if (classes(widget) & {"error-text", "warning-text", "danger"}
                and not (widget.get("text") or "").strip()):
            problems.append(f"{name}: an empty {sorted(classes(widget))} label takes room")

# The values of the summary stand in one column a column of groups.
names = [w for w in widgets("summary") if "muted" in classes(w)]
values = [w for w in widgets("summary")
          if w["type"] == "Label" and "muted" not in classes(w)
          and "section-title" not in classes(w) and (w.get("text") or "").strip()]
columns = {}
for name in names:
    row = [v for v in values if v["y"] == name["y"] and v["x"] > name["x"]]
    if row:
        columns.setdefault(name["x"], set()).add(min(row, key=lambda v: v["x"])["x"])
for left, rights in columns.items():
    if len(rights) != 1:
        problems.append(f"summary: the values of the column at {left} are not in one "
                        f"column: {sorted(rights)}")

# The summary never says "on " without the name of the adapter.
for widget in widgets("summary"):
    text = (widget.get("text") or "").strip()
    if text.endswith("on") or text.endswith("on "):
        problems.append(f"summary: {text!r} says on and nothing else")

# A form of fields does not grow past the width of a form.
for name in ("users", "network"):
    for widget in widgets(name):
        if widget["type"] == "Grid" and widget["w"] > FORM_WIDTH:
            problems.append(f"{name}: a form of fields is {widget['w']} wide, "
                            f"more than {FORM_WIDTH}")

# The controls of the network page stay on the screen: nothing of the
# page is below the fold.
network = pages.get("network")
if network:
    fold = network["frame"]["scroller"][1] + network["frame"]["scroller"][3]
    last = max((w["y"] + w["h"] for w in widgets("network")
                if w["type"] in ("CheckButton", "Button", "Entry", "ComboBoxText")),
               default=0)
    if last > fold:
        problems.append(f"network: a control ends at {last}, below the page ({fold})")

# The strength of the password stands under the password, not between the
# password and its confirmation.
users = pages.get("users")
if users:
    fields = sorted((w for w in widgets("users") if w["type"] == "Entry"),
                    key=lambda w: w["y"])
    bars = [w for w in widgets("users") if w["type"] == "LevelBar"]
    if len(fields) >= 4 and bars:
        password, bar = fields[2], bars[0]
        below = bar["y"] - (password["y"] + password["h"])
        if below > 16:
            problems.append(f"users: the strength of the password is {below} px under the "
                            f"password")

# The buttons of the head of the table of the disks keep their own height:
# the label of the row does not stretch them.
for widget in widgets("disk"):
    if widget["type"] == "Button" and widget.get("text") in (
            "Health details", "Secure erase\u2026", "Look for disks again"):
        if widget.get("valign") == "fill":
            problems.append(f"disk: the button {widget['text']!r} is stretched to the "
                            f"height of the row")

# The cards of the disk page have the same inset.
disk = pages.get("disk")
insets = {}
if disk:
    for widget in widgets("disk"):
        for kind in ("mode-card", "layout-card"):
            if kind in classes(widget):
                what = within(disk, widget)
                if what:
                    insets.setdefault(kind, set()).add(min(w["x"] for w in what) - widget["x"])
if len(insets) > 1 and len({v for values in insets.values() for v in values}) != 1:
    problems.append(f"disk: the cards do not have the same inset: {insets}")

# A card of the installation type has no empty label: an empty label takes
# the room of a line of text.
for widget in widgets("type"):
    if "mode-card" in classes(widget):
        for what in within(pages["type"], widget):
            if (what["type"] == "Label" and classes(what) & {"muted", "warn-text"}
                    and not (what.get("text") or "").strip()):
                problems.append("type: a card of the installation type has an empty label")
                break

# The badges of an item stand next to each other.
rows = {}
for widget in widgets("software"):
    if "badge" in classes(widget):
        rows.setdefault(widget["y"], []).append(widget)
for y, row in rows.items():
    row.sort(key=lambda w: w["x"])
    for first, second in zip(row, row[1:]):
        gap = second["x"] - (first["x"] + first["w"])
        if gap > 16:
            problems.append(f"software: two badges of a row are {gap} px apart")

# The label of the public key stands at the top of its row.
if users:
    keys = [w for w in widgets("users") if w["type"] == "Label"
            and (w.get("text") or "").startswith("SSH public key")]
    views = [w for w in widgets("users") if w["type"] == "TextView"]
    if keys and views:
        if keys[0]["h"] > 24:
            problems.append(f"users: the label of the public key is {keys[0]['h']} px tall")
        if keys[0]["y"] - views[0]["y"] > 16:
            problems.append(f"users: the label of the public key is "
                            f"{keys[0]['y'] - views[0]['y']} px below the text")

# The plan of the disks does not touch the frame around it.
for widget in widgets("summary"):
    if widget["type"] != "ScrolledWindow":
        continue
    what = [w for w in within(pages["summary"], widget) if w["type"] == "Label"]
    if what:
        left = min(text_x(w) for w in what)
        if left - widget["x"] < 4:
            problems.append(f"summary: the plan touches the frame around it "
                            f"({left - widget['x']} px)")

# The buttons of the action bar end where the page ends.
for name, page in pages.items():
    buttons = page.get("frame", {}).get("buttons") or []
    title = page.get("frame", {}).get("title") or {}
    if buttons and title:
        right = max(b["x"] + b["w"] for b in buttons)
        if abs(right - (title["x"] + title["w"])) > 1:
            problems.append(f"{name}: the buttons end at {right}, the page at "
                            f"{title['x'] + title['w']}")

# The text of the welcome page stands at the top of its half, like the
# languages in the other half.
if pages.get("welcome"):
    texts = [w for w in widgets("welcome") if "lead-big" in classes(w)]
    top = min((w["y"] for w in widgets("welcome")), default=0)
    for widget in texts:
        if widget["y"] - top > 24:
            problems.append(f"welcome: the text starts {widget['y'] - top} px below the "
                            f"top of the page")

print("; ".join(problems) or "ok")
PY

# ------------------------------------------------- the display
backend=''
if [ "${have_gi}" = no ]; then
	printf 'skip the drawing checks: GTK 3 for Python (gi) is not installed\n'
elif command -v Xvfb >/dev/null 2>&1; then
	backend=x11
	n=$(( ($$ % 400) + 100 ))
	Xvfb ":${n}" -screen 0 1920x1080x24 -nolisten tcp >/dev/null 2>&1 &
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

# ------------------------------------------------- the pages
if [ -n "${backend}" ]; then
	printf 'drawing on %s\n' "${backend}"
	# The pages are drawn for the system of the fixture, never for the
	# machine the case runs on.
	entry=$(sed -n 's/^default=//p' "${root}/tools/render-fixtures" | head -n 1)
	fixture=${entry%% *}
	conf="${tmp}/installer.conf"
	cp "${root}/installer.conf" "${conf}"
	grep -v '^MIN_DISK_GB=' "${conf}" > "${conf}.new" || :
	mv "${conf}.new" "${conf}"
	min=$(printf '%s\n' "${entry}" | sed -n 's/.* min_disk_gb=\([0-9][0-9]*\).*/\1/p')
	if [ -n "${min}" ]; then
		printf 'MIN_DISK_GB=%s\n' "${min}" >> "${conf}"
	fi
	for size in 1024x768 1920x1080; do
		shots="${tmp}/shots-${size}"
		mkdir -p "${shots}"
		rc=0
		REPO="${root}" "$@" INSTALLER_STATE_PARENT="${tmp}" \
			INSTALLER_ARTWORK="${fixtures}/artwork" \
			INSTALLER_IDENTITY="${fixtures}/identity-default" \
			INSTALLER_CONF="${conf}" \
			INSTALLER_ADAPTER_FIXTURE="${fixtures}/disks/${fixture}" \
			INSTALLER_MNTTAB=/nonexistent INSTALLER_ROOT="${root}" \
			timeout 180 python3 -I -B "${tmp}/draw.py" --render "${root}/tools/shots/docs.json" \
			--size "${size}" --screenshots "${shots}" > "${tmp}/draw-${size}.log" 2>&1 || rc=$?
		check_rc "the pages are drawn at ${size}" 0 "${rc}"
		check "${size}: the pages stand in their columns and take no dead room" "ok" \
			"$(python3 -I -B "${tmp}/check.py" "${shots}")"
	done
fi

finish

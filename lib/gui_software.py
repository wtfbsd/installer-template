# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The page "Additional software": the optional items whose licence the
user has to accept.

Choosing an item accepts its licence; nothing is chosen for the user.
Select all (with three states) ticks every item but those for
non-commercial use or that need a key from the vendor: they need their own
tick.  "Read the licence" shows the full text in the page itself (it works
full-screen and from the keyboard), and the open-source licences are behind
a link.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

import diskplan as D  # noqa: E402
import licensed as L  # noqa: E402

CSS = b"""
.badge { font-size: 10px; padding: 1px 6px; border-radius: 8px; color: #ffffff; }
.badge-non-commercial { background-color: #a05a00; }
.badge-vendor-key { background-color: #7d55a8; }
.badge-download-after-install { background-color: #2f6db5; }
.badge-needs-network { background-color: #1f8f86; }
.item-name { font-weight: bold; font-size: 14px; }
.licence-text { font-family: monospace; }
"""

BADGES = {
    "non-commercial": "Non-commercial use only",
    "vendor-key": "Needs a key from the vendor",
    "download-after-install": "Downloaded after the installation",
    "needs-network": "Needs a network",
}


def lbl(text="", css=None, wrap=True):
    widget = Gtk.Label(label=text)
    widget.set_xalign(0.0)
    widget.set_line_wrap(wrap)
    widget.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for name in (css or "").split():
        widget.get_style_context().add_class(name)
    return widget


class SoftwarePage:
    def __init__(self, win):
        self.win = win
        self.wiz = win.wiz
        self.catalogue = {"items": [], "notices": ""}
        self.selected = []
        self.checks = {}
        self._updating = False

    def build(self):
        self.stack = Gtk.Stack()
        self.stack.set_vhomogeneous(False)
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.pack_start(lbl(
            "This software comes under a licence you have to accept. Choose an item to accept "
            "its licence and have it installed. Nothing is chosen for you.", "lead"), False, False, 0)
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.all_check = Gtk.CheckButton.new_with_mnemonic("Select _all")
        self.all_check.connect("toggled", self.on_all)
        top.pack_start(self.all_check, False, False, 0)
        top.pack_start(lbl("Select all leaves out the items for non-commercial use and the "
                           "items that need a key from the vendor: they need their own tick.",
                           "muted"), True, True, 0)
        page.pack_start(top, False, False, 0)
        self.rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.pack_start(self.rows, False, False, 0)
        notices = Gtk.LinkButton.new_with_label("", "Open-source licences")
        notices.set_halign(Gtk.Align.START)
        # A link never takes the default from the primary action.
        notices.set_receives_default(False)
        notices.connect("activate-link", self.on_notices)
        page.pack_start(notices, False, False, 0)
        self.stack.add_named(page, "list")

        viewer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.viewer_title = lbl("", "type-title")
        viewer.pack_start(self.viewer_title, False, False, 0)
        self.viewer_text = Gtk.TextView()
        self.viewer_text.set_editable(False)
        self.viewer_text.set_cursor_visible(False)
        self.viewer_text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.viewer_text.get_style_context().add_class("licence-text")
        scroller = Gtk.ScrolledWindow()
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.set_min_content_height(320)
        scroller.set_vexpand(True)
        scroller.add(self.viewer_text)
        viewer.pack_start(scroller, True, True, 0)
        close = Gtk.Button.new_with_mnemonic("_Close the licence")
        close.set_halign(Gtk.Align.START)
        close.set_receives_default(False)
        close.connect("clicked", lambda *_a: self.close_viewer())
        self.viewer_close = close
        viewer.pack_start(close, False, False, 0)
        self.stack.add_named(viewer, "licence")
        return self.stack

    def load(self):
        self.catalogue, err = self.wiz.software()
        self.wiz.software_catalogue = self.catalogue
        known = [i["id"] for i in self.catalogue["items"]]
        self.selected = [i for i in self.wiz.answers.accept_licenses if i in known]
        for child in self.rows.get_children():
            self.rows.remove(child)
        self.checks = {}
        if not self.catalogue["items"]:
            self.rows.pack_start(lbl("There is no additional software for this system."
                                     + (f" ({err})" if err else ""), "muted"), False, False, 0)
        for entry in self.catalogue["items"]:
            self.rows.pack_start(self.build_row(entry), False, False, 0)
        self.rows.show_all()
        self.close_viewer()
        self.sync()

    def build_row(self, entry):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        check = Gtk.CheckButton()
        check.set_valign(Gtk.Align.START)
        check.set_active(entry["id"] in self.selected)
        check.connect("toggled", self.on_item, entry["id"])
        self.checks[entry["id"]] = check
        row.pack_start(check, False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        # Everything wraps: the page never grows wider than the screen.
        body.pack_start(lbl(entry["name"], "item-name"), False, False, 0)
        if entry["flags"]:
            # The badges of an item stand next to each other, not spread
            # over the width of the page.
            badges = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            for flag in entry["flags"]:
                badge = lbl(BADGES[flag], f"badge badge-{flag}", wrap=False)
                badge.set_halign(Gtk.Align.START)
                badges.pack_start(badge, False, False, 0)
            body.pack_start(badges, False, False, 0)
        body.pack_start(lbl(entry["description"]), False, False, 0)
        body.pack_start(lbl(f"{D.human(entry['size_bytes'])}  ·  {entry['licence']['title']}",
                            "muted"), False, False, 0)
        read = Gtk.Button(label="Read the licence")
        read.set_halign(Gtk.Align.START)
        read.connect("clicked", lambda *_a, i=entry["id"]: self.open_viewer(i))
        body.pack_start(read, False, False, 0)
        row.pack_start(body, True, True, 0)
        return row

    # ------------------------------------------------------------ events

    def on_item(self, check, ident):
        if self._updating:
            return
        if check.get_active() and ident not in self.selected:
            self.selected.append(ident)
        elif not check.get_active() and ident in self.selected:
            self.selected.remove(ident)
        self.sync()

    def on_all(self, check):
        if self._updating:
            return
        group = L.select_all(self.catalogue)
        if L.select_all_state(self.catalogue, self.selected) == "all":
            self.selected = [i for i in self.selected if i not in group]
        else:
            self.selected += [i for i in group if i not in self.selected]
        self.sync()

    def sync(self):
        """The ticks and the three states of Select all follow the choice."""
        self._updating = True
        try:
            for ident, check in self.checks.items():
                check.set_active(ident in self.selected)
            state = L.select_all_state(self.catalogue, self.selected)
            self.all_check.set_inconsistent(state == "some")
            self.all_check.set_active(state == "all")
            self.all_check.set_sensitive(bool(L.select_all(self.catalogue)))
        finally:
            self._updating = False

    def open_viewer(self, ident):
        entry = L.item(self.catalogue, ident)
        self.viewer_title.set_text(f"{entry['licence']['title']} — {entry['name']}")
        self.viewer_text.get_buffer().set_text(L.licence_text(self.catalogue, ident))
        self.stack.set_visible_child_name("licence")
        self.viewer_close.grab_focus()

    def on_notices(self, *_args):
        self.viewer_title.set_text("Open-source licences")
        self.viewer_text.get_buffer().set_text(L.notices_text(self.catalogue)
                                               or "This system lists no open-source notices.")
        self.stack.set_visible_child_name("licence")
        self.viewer_close.grab_focus()
        return True

    def close_viewer(self):
        self.stack.set_visible_child_name("list")

    def collect(self):
        order = [i["id"] for i in self.catalogue["items"]]
        self.wiz.answers.accept_licenses = [i for i in order if i in self.selected]
        return None

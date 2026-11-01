# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The disk page of the graphical front end.

Three modes, as cards: Erase and install, Install alongside, Manual.  A
table of the disks with health and what is on them now, a partition bar of
every disk before and after, the layouts the operating system offers for
the chosen disks with their usable size and redundancy, the filesystem,
encryption with a strength meter, swap, 4K sectors, TRIM and the boot mode,
optional data disks, and the disk utilities.  The page builds a disk plan
(lib/diskplan.py) and checks it with the same rules the root helper uses.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

import diskplan as D  # noqa: E402
from gui_lists import not_a_list, scrolled  # noqa: E402

CSS = b"""
.mode-card { padding: 10px 14px; border: 2px solid alpha(#000000, 0.15);
    border-radius: 8px; background-color: #ffffff; }
.mode-card:checked { border-color: #4c8bf5; background-image: none; background-color: #eef4ff; }
.mode-title { font-weight: bold; font-size: 15px; }
.type-title { font-weight: bold; font-size: 17px; }
.lead { font-size: 15px; }
.layout-card { padding: 8px 12px; border: 1px solid alpha(#000000, 0.18);
    border-radius: 6px; background-color: #ffffff; }
.layout-card:checked { border-color: #4c8bf5; background-image: none; background-color: #eef4ff; }
.layout-card:disabled { opacity: 0.55; }
.section-title { font-weight: bold; font-size: 14px; margin-top: 6px; }
.muted { color: #666666; }
.danger { color: #c01c28; font-weight: bold; }
.ok-text { color: #26803a; }
.warn-text { color: #a05a00; }
.seg { color: #ffffff; font-size: 10px; padding: 3px 2px; }
.seg-efi { background-color: #5b7f2a; }
.seg-msr { background-color: #8c8c8c; }
.seg-windows { background-color: #2f6db5; }
.seg-recovery { background-color: #6f93c4; }
.seg-linux { background-color: #c98a12; }
.seg-swap { background-color: #7d55a8; }
.seg-free { background-color: #d9d9d9; color: #444444; }
.seg-new { background-color: #2e9d5a; }
.seg-data { background-color: #1f8f86; }
.seg-other { background-color: #9a9a9a; }
.seg-bsd { background-color: #a8323e; }
.seg-encrypted { background-color: #3d3d5c; }
.seg-raid { background-color: #8a6d3b; }
.bar-caption { font-size: 11px; color: #555555; }
"""

BAR_WIDTH = 560
# Where a data disk is mounted unless it is told otherwise.
DATA_MOUNT = "/data"
KNOWN_KINDS = {"efi", "msr", "windows", "recovery", "linux", "swap", "free", "new", "data",
               "bsd", "encrypted", "raid"}


def lbl(text="", css=None, wrap=True, xalign=0.0):
    widget = Gtk.Label(label=text)
    widget.set_xalign(xalign)
    widget.set_line_wrap(wrap)
    widget.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for name in (css or "").split():
        widget.get_style_context().add_class(name)
    return widget


def bar(segments, width=BAR_WIDTH, captions=True):
    """A partition bar: one coloured box per segment, as wide as its share."""
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
    total = sum(max(s["bytes"], 0) for s in segments) or 1
    widths = [max(int(width * s["bytes"] / total), 6) for s in segments]
    if widths:
        # Every bar is exactly as wide: the widest segment gives or takes
        # what the smallest ones took.
        widest = widths.index(max(widths))
        widths[widest] = max(widths[widest] + width - sum(widths), 6)
    for seg, w in zip(segments, widths):
        kind = seg["kind"] if seg["kind"] in KNOWN_KINDS else "other"
        text = f"{seg['label']} {D.human(seg['bytes'])}" if captions and w > 70 else ""
        cell = lbl(text, f"seg seg-{kind}", wrap=False)
        cell.set_ellipsize(Pango.EllipsizeMode.END)
        cell.set_size_request(w, 24)
        cell.set_tooltip_text(f"{seg['label']}: {D.human(seg['bytes'])}")
        box.pack_start(cell, False, False, 0)
    return box


class DiskPage:
    """The widgets and the state of the disk page."""

    def __init__(self, win):
        self.win = win
        self.wiz = win.wiz
        self.os = self.wiz.os_name
        self.detail = {"disks": []}
        self.mode = "erase"
        self.selected = []          # the system disks of Erase and install
        self.layout = ""
        self.wipe = {}
        self.data_disks = []
        self.partitions = []        # the partitions of Manual
        self.regions = []           # the free regions of Install alongside
        self.usage = None           # "together" or "separate" with two disks or more
        self.separate = {}          # disk -> mount point, or None to leave it
        self.data_checks = {}
        self.errors = []

    # ------------------------------------------------------------ build

    def build(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        # Two disks or more: together or separately?  Nothing is chosen
        # for the user.
        self.usage_area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.usage_area.pack_start(lbl("This machine has more than one disk. How should "
                                       f"{self.wiz.product} use them?", "lead"), False, False, 0)
        usage_cards = not_a_list(Gtk.FlowBox(), "two cards: together or separately")
        usage_cards.set_selection_mode(Gtk.SelectionMode.NONE)
        usage_cards.set_homogeneous(True)
        usage_cards.set_min_children_per_line(2)
        usage_cards.set_max_children_per_line(2)
        usage_cards.set_column_spacing(12)
        self.usage_none = Gtk.RadioButton()
        self.usage_buttons = {}
        for ident, title, text in (
                ("together", "Use the disks together",
                 "One pool across the disks you choose: more space, or copies of the system "
                 "that survive a failed disk."),
                ("separate", "Use the disks separately",
                 "The system on one disk; every other disk stays its own drive, left as it is "
                 "or formatted for /data, /home and the like.")):
            button = Gtk.RadioButton.new_from_widget(self.usage_none)
            button.set_mode(False)
            button.get_style_context().add_class("mode-card")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            inner.set_border_width(4)
            inner.pack_start(lbl(title, "type-title"), False, False, 0)
            desc = lbl(text, "muted")
            desc.set_max_width_chars(40)
            inner.pack_start(desc, False, False, 0)
            button.add(inner)
            button.connect("toggled", self.on_usage, ident)
            self.usage_buttons[ident] = button
            usage_cards.add(button)
        self.usage_area.pack_start(usage_cards, False, False, 0)
        page.pack_start(self.usage_area, False, False, 0)

        # The disks (Erase and install, Manual).
        self.table_area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.pack_start(self.table_area, False, False, 0)
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        head.pack_start(lbl("Disks (the disk the live system runs from is not listed)",
                            "section-title"), True, True, 0)
        for text, handler in (("Health details", self.on_health),
                              ("Secure erase…", self.on_secure_erase),
                              ("Look for disks again", lambda *_a: self.load())):
            button = Gtk.Button(label=text)
            button.connect("clicked", handler)
            head.pack_start(button, False, False, 0)
        self.table_area.pack_start(head, False, False, 0)
        self.store = Gtk.ListStore(bool, str, str, str, str, str, str, str, str)
        self.view = Gtk.TreeView(model=self.store)
        toggle = Gtk.CellRendererToggle()
        toggle.connect("toggled", self.on_toggle)
        self.use_column = Gtk.TreeViewColumn("Use", toggle, active=0)
        self.view.append_column(self.use_column)
        for index, title in enumerate(("Device", "Model", "Size", "Serial", "Bus", "Type"), start=1):
            renderer = Gtk.CellRendererText()
            if title == "Model":
                renderer.set_property("ellipsize", Pango.EllipsizeMode.END)
            column = Gtk.TreeViewColumn(title, renderer, text=index)
            column.set_expand(title == "Model")
            self.view.append_column(column)
        health = Gtk.CellRendererText()
        health.set_property("ellipsize", Pango.EllipsizeMode.END)
        column = Gtk.TreeViewColumn("Health", health, markup=7)
        column.set_min_width(80)
        column.set_resizable(True)
        self.view.append_column(column)
        contents = Gtk.CellRendererText()
        contents.set_property("ellipsize", Pango.EllipsizeMode.END)
        column = Gtk.TreeViewColumn("On it now", contents, text=8)
        column.set_expand(True)
        self.view.append_column(column)
        self.view.get_selection().connect("changed", lambda *_a: None)
        self.view.connect("row-activated", lambda *_a: self.on_health())
        # The table scrolls sideways on a narrow screen; the page never
        # grows wider than the screen.
        # Many disks: at most seven rows, the rest scrolls.
        table = scrolled(self.view, 3, 5, name="disks")
        table.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.table_area.pack_start(table, False, False, 0)
        self.warnings = lbl("", "warn-text")
        page.pack_start(self.warnings, False, False, 0)

        # Before and after.
        # What every mode asks, right after the disks it is about.
        self.mode_stack = Gtk.Stack()
        self.mode_stack.set_vhomogeneous(False)
        self.mode_stack.add_named(self.build_erase(), "erase")
        self.mode_stack.add_named(self.build_alongside(), "alongside")
        self.mode_stack.add_named(self.build_manual(), "manual")
        page.pack_start(self.mode_stack, False, False, 0)

        # Before and after: one pair of bars a disk; many disks scroll.
        self.bars_area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.bars_area.pack_start(lbl("Before and after", "section-title"), False, False, 0)
        self.bars = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.bars_area.pack_start(scrolled(self.bars, 2, 5, name="bars"), False, False, 0)
        page.pack_start(self.bars_area, False, False, 0)

        # Data disks.
        self.data_expander = Gtk.Expander(label="Data disks (optional)")
        self.data_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        # The other disks scroll; the mount point and layout below stay.
        self.data_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.data_box.pack_start(scrolled(self.data_list, 2, 4, name="data-disks"), False, False, 0)
        self.data_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.data_box.pack_start(self.data_row, False, False, 0)
        self.data_expander.add(self.data_box)
        # With the folded choices of Erase and install.
        self.advanced_box.pack_start(self.data_expander, False, False, 0)

        self.problems = lbl("", "danger")
        page.pack_start(self.problems, False, False, 0)
        return page

    # ------------------------------------------------------------ type

    ILLUSTRATIONS = {
        "erase": ([("windows", 50), ("linux", 30), ("free", 20)], [("efi", 4), ("new", 96)]),
        "alongside": ([("windows", 55), ("free", 45)], [("windows", 55), ("new", 45)]),
        "manual": ([("free", 100)], [("efi", 4), ("swap", 10), ("new", 56), ("data", 30)]),
    }

    def build_type(self):
        """The page "Installation type": three cards and what the machine
        holds."""
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        # One installable disk with nothing on it: a notice instead of the
        # cards; there is nothing to choose.
        self.notice = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.notice_disk = lbl("", "type-title")
        self.notice.pack_start(self.notice_disk, False, False, 0)
        self.notice_text = lbl("", "lead")
        self.notice.pack_start(self.notice_text, False, False, 0)
        self.notice_bars = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.notice.pack_start(self.notice_bars, False, False, 0)
        manual = Gtk.LinkButton.new_with_label("", "Partition manually instead")
        manual.set_halign(Gtk.Align.START)
        manual.set_receives_default(False)
        manual.connect("activate-link", self.on_manual_instead)
        self.notice.pack_start(manual, False, False, 0)
        page.pack_start(self.notice, False, False, 0)
        self.type_question = lbl(f"How should {self.wiz.product} be installed?", "lead")
        page.pack_start(self.type_question, False, False, 0)
        self.cards_area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        page.pack_start(self.cards_area, False, False, 0)
        cards = not_a_list(Gtk.FlowBox(), "the three installation types")
        cards.set_selection_mode(Gtk.SelectionMode.NONE)
        cards.set_homogeneous(True)
        cards.set_min_children_per_line(1)
        cards.set_max_children_per_line(3)
        cards.set_column_spacing(12)
        cards.set_row_spacing(12)
        self.mode_buttons = {}
        self.type_reason = {}
        self.type_warning = {}
        group = None
        for ident, title in (("erase", "Erase and install"), ("alongside", "Install alongside"),
                             ("manual", "Manual")):
            button = Gtk.RadioButton.new_from_widget(group)
            group = group or button
            button.set_mode(False)
            button.get_style_context().add_class("mode-card")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            inner.set_border_width(6)
            inner.pack_start(lbl(title, "type-title"), False, False, 0)
            line = lbl("", "muted")
            line.set_max_width_chars(30)
            inner.pack_start(line, False, False, 0)
            before, after = self.ILLUSTRATIONS[ident]
            pic = Gtk.Grid(column_spacing=6, row_spacing=3)
            for row, (caption, segs) in enumerate((("now", before), ("after", after))):
                pic.attach(lbl(caption, "bar-caption", wrap=False), 0, row, 1, 1)
                pic.attach(bar([{"kind": k, "label": k, "bytes": w} for k, w in segs], 200, False),
                           1, row, 1, 1)
            inner.pack_start(pic, False, False, 4)
            reason = lbl("", "muted")
            reason.set_max_width_chars(30)
            warning = lbl("", "warn-text")
            warning.set_max_width_chars(30)
            inner.pack_start(reason, False, False, 0)
            inner.pack_start(warning, False, False, 0)
            button.add(inner)
            button.connect("toggled", self.on_mode, ident)
            self.mode_buttons[ident] = button
            self.type_reason[ident] = reason
            self.type_warning[ident] = warning
            self.type_line = getattr(self, "type_line", {})
            self.type_line[ident] = line
            cards.add(button)
        self.cards_area.pack_start(cards, False, False, 0)
        self.cards_area.pack_start(lbl("The disks of this machine", "section-title"), False, False, 0)
        self.machine_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.cards_area.pack_start(self.machine_box, False, False, 0)
        return page

    def on_manual_instead(self, *_args):
        self.mode_buttons["manual"].set_active(True)
        self.win.act_next()
        return True

    def load_type(self):
        """Fill the page "Installation type" from the report of the disks."""
        self.load()
        single = D.single_blank(self.detail)
        self.notice.set_visible(single)
        self.type_question.set_visible(not single)
        self.cards_area.set_visible(not single)
        if single:
            disk = self.detail["disks"][0]
            self.selected = [disk["name"]]
            self.mode_buttons["erase"].set_active(True)
            self.notice_disk.set_text(f"{disk['name']}  {disk.get('model', '')}  "
                                      f"{D.human(int(disk.get('size_bytes', 0)))}")
            self.notice_text.set_text(f"This disk is empty. {self.wiz.product} will use the whole disk.")
            for child in self.notice_bars.get_children():
                self.notice_bars.remove(child)
            plan = {"mode": "erase", "disks": [disk["name"]],
                    "swap_mb": int(self.swap.get_value()) * 1024, "filesystem": self.fs_combo.get_active_id()}
            grid = Gtk.Grid(column_spacing=10, row_spacing=4)
            grid.attach(lbl("now", "bar-caption", wrap=False), 0, 0, 1, 1)
            grid.attach(bar(D.bar_before(disk)), 1, 0, 1, 1)
            grid.attach(lbl("after", "bar-caption", wrap=False), 0, 1, 1, 1)
            grid.attach(bar(D.bar_after(disk, plan, self.os, self.wiz.product)), 1, 1, 1, 1)
            self.notice_bars.pack_start(grid, False, False, 0)
            self.notice_bars.show_all()
            return
        types = {t["ident"]: t for t in D.install_types(self.detail, self.wiz.product, self.os)}
        for ident, info in types.items():
            self.type_line[ident].set_text(info["line"])
            self.type_reason[ident].set_text(f"Not possible: {info['reason']}" if info["reason"] else "")
            self.type_warning[ident].set_text(info["warning"])
            self.mode_buttons[ident].set_sensitive(info["available"])
        if not types[self.mode]["available"]:
            self.mode_buttons["erase"].set_active(True)
        for child in self.machine_box.get_children():
            self.machine_box.remove(child)
        for line in D.machine_summary(self.detail) or ["No disk was found."]:
            self.machine_box.pack_start(lbl(line), False, False, 0)
        self.machine_box.show_all()

    def collect_type(self):
        types = {t["ident"]: t for t in D.install_types(self.detail, self.wiz.product, self.os)}
        if not types[self.mode]["available"]:
            return types[self.mode]["reason"]
        return None

    def mode_title(self):
        return {"erase": "Erase and install", "alongside": "Install alongside",
                "manual": "Manual"}[self.mode]

    def asks_usage(self):
        return self.mode == "erase" and D.needs_usage_question(self.detail)

    def apply_mode(self):
        """The Disk page shows what fits the chosen type only; with two
        disks or more, Erase and install first asks together or
        separately and shows the rest once it is answered."""
        self.mode_stack.set_visible_child_name(self.mode)
        asks = self.asks_usage()
        answered = not asks or self.usage is not None
        self.usage_area.set_visible(asks)
        self.table_area.set_visible(self.mode == "manual" or (self.mode == "erase" and answered))
        self.mode_stack.set_visible(self.mode != "erase" or answered)
        self.bars_area.set_visible(self.mode != "erase" or answered)
        self.use_column.set_visible(self.mode == "erase")
        self.use_column.set_title("System" if self.usage == "separate" else "Use")
        separate = asks and self.usage == "separate"
        pools = D.data_pools_offered(self.os, self.detail)
        self.data_expander.set_visible(self.mode == "erase" and answered and not separate and pools)
        # Separately is always possible: the other disks can be left as
        # they are; formatting them needs data disks (see fill_separate).
        caption = lbl("Disks outside the system pool (optional): each formatted as its own drive"
                      if asks else "Data disks (optional)")
        caption.set_max_width_chars(40)
        caption.show()
        self.data_expander.set_label_widget(caption)
        self.separate_area.set_visible(separate)
        self.layout_title.set_visible(not separate)
        self.layout_grid.set_visible(not separate)

    def build_erase(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.separate_area = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.separate_area.pack_start(lbl("The other disks", "section-title"), False, False, 0)
        # One row a disk: many disks scroll.
        self.separate_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.separate_area.pack_start(scrolled(self.separate_list, 2, 3, row_px=40, name="other-disks"),
                                      False, False, 0)
        box.pack_start(self.separate_area, False, False, 0)
        self.layout_title = lbl("Layout", "section-title")
        box.pack_start(self.layout_title, False, False, 0)
        self.layout_grid = not_a_list(Gtk.FlowBox(), "the layout cards of the system (a handful)")
        self.layout_grid.set_selection_mode(Gtk.SelectionMode.NONE)
        self.layout_grid.set_max_children_per_line(4)
        self.layout_grid.set_min_children_per_line(1)
        self.layout_grid.set_column_spacing(8)
        self.layout_grid.set_row_spacing(8)
        self.layout_grid.set_homogeneous(True)
        box.pack_start(self.layout_grid, False, False, 0)
        self.layout_more = lbl("", "muted")
        box.pack_start(self.layout_more, False, False, 0)

        grid = Gtk.Grid(column_spacing=14, row_spacing=8)
        row = 0
        # The choices most people keep fold into "Advanced", with one line
        # that says what they are; the layout and encryption stay in view.
        adv = Gtk.Grid(column_spacing=14, row_spacing=8)
        adv.set_margin_top(6)
        arow = 0
        fss = D.filesystems(self.os)
        self.fs_combo = Gtk.ComboBoxText()
        for ident, title in fss:
            self.fs_combo.append(ident, title)
        self.fs_combo.set_active_id(fss[0][0])
        self.fs_combo.connect("changed", lambda *_a: self.refresh())
        if len(fss) > 1:
            adv.attach(lbl("Filesystem", "field-label"), 0, arow, 1, 1)
            adv.attach(self.fs_combo, 1, arow, 2, 1)
            arow += 1
        enc_name = D.system(self.os)["encryption"]
        self.enc_check = Gtk.CheckButton(
            label=f"Encrypt the system ({enc_name}); the passphrase is asked at every start")
        self.enc_check.connect("toggled", lambda *_a: self.refresh())
        grid.attach(self.enc_check, 0, row, 3, 1)
        row += 1
        self.pass1 = Gtk.Entry(visibility=False, placeholder_text="Passphrase")
        self.pass2 = Gtk.Entry(visibility=False, placeholder_text="Confirm the passphrase")
        for entry in (self.pass1, self.pass2):
            entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            entry.connect("changed", lambda *_a: self.refresh_strength())
        self.strength = Gtk.LevelBar(min_value=0, max_value=4)
        self.strength.set_size_request(160, 10)
        self.strength_text = lbl("", "muted")
        grid.attach(self.pass1, 0, row, 1, 1)
        grid.attach(self.pass2, 1, row, 1, 1)
        meter = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        meter.pack_start(self.strength, False, False, 0)
        meter.pack_start(self.strength_text, False, False, 0)
        grid.attach(meter, 2, row, 1, 1)
        self.pass_row = [self.pass1, self.pass2, meter]
        row += 1
        adv.attach(lbl("Swap", "field-label"), 0, arow, 1, 1)
        swap_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.swap = Gtk.SpinButton.new_with_range(0, 1024, 1)
        self.swap.connect("value-changed", lambda *_a: self.refresh())
        swap_box.pack_start(self.swap, False, False, 0)
        swap_box.pack_start(lbl("GB", "muted"), False, False, 0)
        self.swap_enc = Gtk.CheckButton(label="Encrypt the swap")
        self.swap_enc.connect("toggled", lambda *_a: self.refresh())
        swap_box.pack_start(self.swap_enc, False, False, 12)
        adv.attach(swap_box, 1, arow, 2, 1)
        arow += 1
        self.sector_4k = Gtk.CheckButton(label="Align for 4K sectors")
        self.sector_4k.set_active(True)
        self.trim = Gtk.CheckButton(label="TRIM on solid state disks")
        self.trim.set_active(True)
        self.sector_4k.connect("toggled", lambda *_a: self.refresh_advanced())
        self.trim.connect("toggled", lambda *_a: self.refresh_advanced())
        adv.attach(self.sector_4k, 0, arow, 1, 1)
        adv.attach(self.trim, 1, arow, 1, 1)
        arow += 1
        adv.attach(lbl("Start the system with", "field-label"), 0, arow, 1, 1)
        self.boot_combo = Gtk.ComboBoxText()
        for ident in D.system(self.os)["boot"]:
            self.boot_combo.append(ident, {"uefi": "UEFI", "bios": "Legacy BIOS"}[ident])
        self.boot_combo.set_active_id("uefi")
        self.boot_combo.connect("changed", lambda *_a: self.refresh())
        adv.attach(self.boot_combo, 1, arow, 1, 1)
        self.boot_warning = lbl("", "warn-text")
        adv.attach(self.boot_warning, 2, arow, 1, 1)
        box.pack_start(grid, False, False, 0)
        self.advanced_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.advanced_box.pack_start(adv, False, False, 0)
        self.advanced = Gtk.Expander()
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        head.pack_start(lbl("_Advanced", "field-label", wrap=False), False, False, 0)
        head.get_children()[0].set_use_underline(True)
        self.advanced_summary = lbl("", "muted", wrap=False)
        head.pack_start(self.advanced_summary, False, False, 0)
        self.advanced.set_label_widget(head)
        self.advanced.set_use_underline(True)
        self.advanced.add(self.advanced_box)
        box.pack_start(self.advanced, False, False, 0)
        return box

    def refresh_advanced(self):
        """The one line of the folded choices: filesystem, swap, start,
        TRIM and 4K, the data disks."""
        if not hasattr(self, "advanced_summary"):
            return
        parts = []
        fs_title = dict(D.filesystems(self.os)).get(self.fs_combo.get_active_id() or "", "")
        if fs_title:
            parts.append(fs_title.split(" (")[0])
        swap = int(self.swap.get_value())
        parts.append(f"swap {swap} GB" if swap else "no swap")
        boot = self.boot_combo.get_active_id()
        if boot:
            parts.append({"uefi": "UEFI", "bios": "Legacy BIOS"}.get(boot, boot))
        parts.append("TRIM on" if self.trim.get_active() else "TRIM off")
        if self.sector_4k.get_active():
            parts.append("4K")
        data = getattr(self, "data_disks", [])
        if data:
            parts.append(f"{len(data)} data disk{'s' if len(data) != 1 else ''}")
        self.advanced_summary.set_text(" \u00b7 ".join(parts))

    def build_alongside(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(lbl("Free space", "section-title"), False, False, 0)
        self.along_text = lbl("", "muted")
        box.pack_start(self.along_text, False, False, 0)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.region_combo = Gtk.ComboBoxText()
        self.region_combo.connect("changed", lambda *_a: self.on_region())
        row.pack_start(self.region_combo, False, False, 0)
        self.size_scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 1, 100, 1)
        self.size_scale.set_hexpand(True)
        self.size_scale.set_digits(0)
        self.size_scale.connect("value-changed", lambda *_a: self.refresh())
        row.pack_start(self.size_scale, True, True, 0)
        self.size_text = lbl("", wrap=False)
        row.pack_start(self.size_text, False, False, 0)
        box.pack_start(row, False, False, 0)
        box.pack_start(lbl(
            "The existing EFI partition is reused and the new system is added to its boot "
            "menu. No partition and no filesystem of another system is resized or changed.",
            "muted"), False, False, 0)
        return box

    def build_manual(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(lbl("Partitions", "section-title"), False, False, 0)
        self.part_store = Gtk.ListStore(str, str, str, str)
        self.part_view = Gtk.TreeView(model=self.part_store)
        for index, title in enumerate(("Disk", "Type", "Size", "Mount point")):
            self.part_view.append_column(Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index))
        box.pack_start(scrolled(self.part_view, 3, 8, name="partitions"), False, False, 0)
        row = not_a_list(Gtk.FlowBox(), "the controls that add a partition, laid out")
        row.set_selection_mode(Gtk.SelectionMode.NONE)
        row.set_max_children_per_line(6)
        row.set_column_spacing(8)
        self.part_disk = Gtk.ComboBoxText()
        self.part_type = Gtk.ComboBoxText()
        for ident, title in (("efi", "EFI system"), ("bios-boot", "BIOS boot"), ("root", "Root (/)"),
                             ("swap", "Swap"), ("data", "Data")):
            self.part_type.append(ident, title)
        self.part_type.set_active_id("root")
        self.part_size = Gtk.SpinButton.new_with_range(0, 1 << 30, 1024)
        self.part_size.set_tooltip_text("Size in MB; 0 takes the rest of the disk")
        self.part_mount = Gtk.Entry(placeholder_text="/ or /home")
        add = Gtk.Button(label="Add")
        add.connect("clicked", self.on_add_partition)
        remove = Gtk.Button(label="Remove the last")
        remove.connect("clicked", self.on_remove_partition)
        for widget in (self.part_disk, self.part_type, self.part_size, self.part_mount, add, remove):
            row.add(widget)
        box.pack_start(row, False, False, 0)
        box.pack_start(lbl("Sizes in MB; 0 is the rest of the disk. There must be one root (/) "
                           "and, to start with UEFI, an EFI partition.", "muted"), False, False, 0)
        return box

    # ------------------------------------------------------------ data

    def load(self):
        """Read the report of the disks again and fill the page."""
        self.detail, err = self.wiz.disk_report()
        index = D.disk_index(self.detail)
        self.selected = [n for n in self.selected if n in index]
        if not self.selected and index:
            self.selected = [next(iter(index))]
        self.data_disks = [n for n in self.data_disks if n in index and n not in self.selected]
        self.fill_table()
        self.part_disk.remove_all()
        for name in index:
            self.part_disk.append(name, name)
        if index:
            self.part_disk.set_active(0)
        ram = int(self.detail.get("ram_mb", 0))
        if self.swap.get_value() == 0 and not getattr(self, "_swap_set", False):
            self.swap.set_value(round(D.default_swap_mb(ram) / 1024))
            self._swap_set = True
        self.fill_regions()
        self.fill_data()
        if err:
            self.problems.set_text(err)
        self.refresh()

    def fill_table(self):
        self.store.clear()
        for disk in self.detail.get("disks", []):
            health = disk.get("health", {})
            status = health.get("status", "unknown")
            colour = {"ok": "#26803a", "warning": "#a05a00", "failing": "#c01c28"}.get(status, "#666666")
            summary = health.get("summary") or status
            on_it = []
            if disk.get("os"):
                on_it.append(", ".join(D.foreign(disk)))
            if disk.get("partitions"):
                on_it.append(f"{disk.get('scheme') or 'partitions'}: {len(disk['partitions'])} partitions")
            elif not disk.get("os"):
                on_it.append("empty")
            kind = {True: "SSD", False: "HDD"}.get(disk.get("ssd"), "")
            self.store.append([
                disk["name"] in self.selected, disk["name"], disk.get("model", ""),
                D.human(int(disk.get("size_bytes", 0))), disk.get("serial", ""),
                disk.get("bus", ""), kind,
                f'<span foreground="{colour}">{glib_escape(summary)}</span>', "; ".join(on_it)])

    def fill_regions(self):
        self.region_combo.remove_all()
        self.regions = []
        for disk in self.detail.get("disks", []):
            for free in disk.get("free", []):
                if free.get("size_mb", 0) >= 16384:
                    self.regions.append((disk["name"], free))
                    self.region_combo.append(
                        str(len(self.regions) - 1),
                        f"{disk['name']}: {D.human(free['size_mb'] * D.MiB)} free")
        if self.regions:
            self.region_combo.set_active(0)
            self.along_text.set_text("Choose the free space and how much of it the new system uses.")
        else:
            self.along_text.set_text("No disk has free space of 16 GB or more: use Erase and install "
                                     "or Manual instead.")

    def fill_data(self):
        for holder in (self.data_list, self.data_row):
            for child in holder.get_children():
                holder.remove(child)
        self.data_checks = {}
        others = [d for d in self.detail.get("disks", []) if d["name"] not in self.selected]
        if not others:
            self.data_list.pack_start(lbl("Every disk is a system disk.", "muted"), False, False, 0)
            self.data_mount = Gtk.Entry(text=DATA_MOUNT)
            self.data_layout = Gtk.ComboBoxText()
            self.data_layout.append("single", "single")
            self.data_layout.set_active_id("single")
            self.data_box.show_all()
            return
        for disk in others:
            check = Gtk.CheckButton(label=f"{disk['name']}  {disk.get('model', '')}  "
                                          f"{D.human(int(disk.get('size_bytes', 0)))}")
            check.set_active(disk["name"] in self.data_disks)
            check.connect("toggled", self.on_data_toggle, disk["name"])
            self.data_checks[disk["name"]] = check
            self.data_list.pack_start(check, False, False, 0)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.data_mount = Gtk.Entry(text=DATA_MOUNT, width_chars=10)
        self.data_layout = Gtk.ComboBoxText()
        for item in D.layouts(self.os):
            self.data_layout.append(item.ident, item.title)
        self.data_layout.set_active_id("single")
        row.pack_start(lbl("Mounted on", wrap=False), False, False, 0)
        row.pack_start(self.data_mount, False, False, 0)
        row.pack_start(lbl("Layout", wrap=False), False, False, 0)
        row.pack_start(self.data_layout, False, False, 0)
        self.data_row.pack_start(row, False, False, 0)
        self.data_box.show_all()

    # ------------------------------------------------------------ events

    def on_mode(self, button, ident):
        if button.get_active():
            self.mode = ident
            if hasattr(self, "mode_stack"):
                self.apply_mode()
                self.refresh()

    def on_usage(self, button, ident):
        if not button.get_active():
            return
        self.usage = ident
        # The question is answered: a message that asked for it goes.
        self.win.show_error("")
        if ident == "separate":
            self.selected = self.selected[:1] or [self.detail["disks"][0]["name"]]
            self.data_disks = []
            self.separate = {d["name"]: None for d in self.detail.get("disks", [])
                             if d["name"] not in self.selected}
            self.fill_separate()
        self.fill_table()
        self.apply_mode()
        self.refresh()

    def fill_separate(self):
        for child in self.separate_list.get_children():
            self.separate_list.remove(child)
        index = D.disk_index(self.detail)
        for name in sorted(self.separate):
            disk = index.get(name, {})
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.pack_start(lbl(f"{name}  {disk.get('model', '')}  "
                               f"{D.human(int(disk.get('size_bytes', 0)))}", wrap=False), False, False, 0)
            combo = Gtk.ComboBoxText()
            combo.append("keep", "Leave it as it is")
            if D.data_pools_offered(self.os, self.detail):
                combo.append("format", "Format it as a drive on")
            mount = Gtk.Entry(width_chars=10)
            mount.set_text(self.separate[name] or (DATA_MOUNT if not any(self.separate.values()) else "/home"))
            combo.set_active_id("format" if self.separate[name] else "keep")
            mount.set_sensitive(bool(self.separate[name]))

            def changed(*_a, name=name, combo=combo, mount=mount):
                fmt = combo.get_active_id() == "format"
                mount.set_sensitive(fmt)
                self.separate[name] = mount.get_text().strip() if fmt else None
                self.refresh()
            combo.connect("changed", changed)
            mount.connect("changed", changed)
            row.pack_start(combo, False, False, 0)
            row.pack_start(mount, False, False, 0)
            self.separate_list.pack_start(row, False, False, 0)
        if not D.data_pools_offered(self.os, self.detail) and self.separate:
            # Said, not greyed: why the other disks can only be kept.
            self.separate_list.pack_start(
                lbl("Formatting the other disks as drives is "
                    f"{D.system(self.os, self.detail)['not_offered']}; they are left as they are.",
                    "muted"), False, False, 0)
        self.separate_area.show_all()

    def on_toggle(self, _renderer, path):
        name = self.store[path][1]
        if self.asks_usage() and self.usage == "separate":
            # One system disk: the toggle is a choice.
            self.selected = [name]
            self.separate = {d["name"]: self.separate.get(d["name"]) for d in self.detail["disks"]
                             if d["name"] != name}
            for row in self.store:
                row[0] = row[1] == name
            self.fill_separate()
            self.refresh()
            return
        if name in self.selected:
            self.selected.remove(name)
        else:
            self.selected.append(name)
            if name in self.data_disks:
                self.data_disks.remove(name)
        self.store[path][0] = name in self.selected
        self.layout = ""
        self.fill_data()
        self.refresh()

    def on_data_toggle(self, check, name):
        if check.get_active() and name not in self.data_disks:
            self.data_disks.append(name)
        elif not check.get_active() and name in self.data_disks:
            self.data_disks.remove(name)
        self.refresh()

    def on_layout(self, button, ident):
        if button.get_active():
            self.layout = ident
            self.lock_encryption()
            self.refresh_bars()
            self.refresh_problems()

    def lock_encryption(self):
        """A layout that is an encryption (CRYPTO, RAID 1C) ticks and locks
        the encryption box: the passphrase is then asked for; any other
        layout leaves the box to the person."""
        item = D.layout(self.os, self.layout or "", self.detail)
        locked = bool(item is not None and item.encrypted)
        if locked and not self.enc_check.get_active():
            self.enc_check.set_active(True)
        self.enc_check.set_sensitive(not locked)
        self.enc_check.set_tooltip_text(
            f"The layout {item.title} is an encryption." if locked else None)

    def on_region(self):
        index = self.region_combo.get_active()
        if index < 0 or index >= len(self.regions):
            return
        free = self.regions[index][1]
        top = max(free["size_mb"] // 1024, 1)
        self.size_scale.set_range(min(16, top), top)
        self.size_scale.set_value(top)
        self.refresh()

    def on_add_partition(self, *_args):
        disk = self.part_disk.get_active_id()
        ptype = self.part_type.get_active_id()
        if not disk or not ptype:
            return
        mount = self.part_mount.get_text().strip()
        if ptype == "root":
            mount = "/"
        elif ptype == "efi":
            mount = "/boot/efi"
        elif ptype in ("swap", "bios-boot"):
            mount = ""
        part = {"disk": disk, "type": ptype, "size_mb": int(self.part_size.get_value())}
        if mount:
            part["mount"] = mount
        self.partitions.append(part)
        self.fill_partitions()
        self.refresh()

    def on_remove_partition(self, *_args):
        if self.partitions:
            self.partitions.pop()
            self.fill_partitions()
            self.refresh()

    def fill_partitions(self):
        self.part_store.clear()
        for part in self.partitions:
            self.part_store.append([part["disk"], part["type"],
                                    D.human_mb(part["size_mb"]) if part["size_mb"] else "the rest",
                                    part.get("mount", "")])

    def current_disk(self):
        model, it = self.view.get_selection().get_selected()
        if it is not None:
            return model[it][1]
        return self.selected[0] if self.selected else ""

    def on_health(self, *_args):
        name = self.current_disk()
        disk = D.disk_index(self.detail).get(name)
        if not disk:
            return
        h = disk.get("health", {})
        lines = [f"Status: {h.get('summary') or h.get('status', 'unknown')}"]
        for key, title, unit in (("temperature_c", "Temperature", " °C"),
                                 ("power_on_hours", "Powered on", " hours"),
                                 ("reallocated", "Reallocated sectors", ""),
                                 ("pending", "Pending sectors", ""),
                                 ("wear_percent", "Wear", " %")):
            if h.get(key) is not None:
                lines.append(f"{title}: {h[key]}{unit}")
        self.win.message(f"Health of {name} ({disk.get('model', '')})", "\n".join(lines))

    def on_secure_erase(self, *_args):
        name = self.current_disk()
        if not name:
            return
        typed = self.win.ask_text(
            f"Securely erase {name}?",
            f"Every block of {name} is overwritten when the installation starts. This takes "
            f"a long time and nothing on {name} can be recovered.\nType {name} to confirm.")
        if typed == name:
            self.wipe[name] = "secure"
            self.refresh()

    # ------------------------------------------------------------ state

    def refresh_strength(self):
        score, word = D.passphrase_strength(self.pass1.get_text())
        self.strength.set_value(score)
        mismatch = self.pass2.get_text() and self.pass1.get_text() != self.pass2.get_text()
        self.strength_text.set_text("the passphrases do not match" if mismatch else f"strength: {word}")

    def refresh(self):
        if not hasattr(self, "layout_grid"):
            return
        self.refresh_advanced()
        index = D.disk_index(self.detail)
        sizes = [int(index[n].get("size_bytes", 0)) for n in self.selected if n in index]
        cards = D.layout_cards(self.os, sizes, self.detail)
        if not self.layout or all(c["ident"] != self.layout or c["reason"] for c in cards):
            self.layout = D.default_layout(self.os, len(sizes), self.detail)
        self.fill_layout_cards(cards)
        self.lock_encryption()
        # Disks used separately: the system takes a single disk, no layout.
        self.layout_grid.set_visible(not (self.asks_usage() and self.usage == "separate"))
        enc = self.enc_check.get_active()
        for widget in self.pass_row:
            widget.set_sensitive(enc)
        self.swap_enc.set_sensitive(self.swap.get_value() > 0)
        self.boot_warning.set_text(self.boot_warning_text())
        if self.regions:
            self.size_text.set_text(f"{int(self.size_scale.get_value())} GB for {self.wiz.product}")
        self.refresh_strength()
        self.refresh_bars()
        self.refresh_problems()

    def fill_layout_cards(self, cards):
        """The layout cards of the chosen disks, and the line of the others."""
        for child in self.layout_grid.get_children():
            self.layout_grid.remove(child)
        group = None
        # Only the layouts the chosen disks allow are cards; the others are
        # one line that says what each needs (the page stays short).
        others = [c for c in cards if c["reason"]]
        self.layout_more.set_text(
            "Need more disks: " + ", ".join(f"{c['title']} ({c['min_disks']}+)" for c in others)
            if others else "")
        # Used separately the system takes one disk: no layout, no note.
        self.layout_more.set_visible(bool(others) and not (self.asks_usage() and self.usage == "separate"))
        for card in [c for c in cards if not c["reason"]]:
            button = Gtk.RadioButton.new_from_widget(group)
            group = group or button
            button.set_mode(False)
            button.get_style_context().add_class("layout-card")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
            inner.pack_start(lbl(card["title"], "mode-title"), False, False, 0)
            inner.pack_start(lbl(f"{D.human(card['usable_bytes'])} usable"), False, False, 0)
            inner.pack_start(lbl(card["redundancy"], "muted"), False, False, 0)
            button.add(inner)
            button.set_sensitive(not card["reason"])
            if card["ident"] == self.layout:
                button.set_active(True)
            button.connect("toggled", self.on_layout, card["ident"])
            self.layout_grid.add(button)
        self.layout_grid.show_all()

    def boot_warning_text(self):
        """The warning when the chosen boot differs from how the machine started."""
        booted = self.detail.get("boot_mode", "")
        chosen = self.boot_combo.get_active_id()
        if not booted or chosen == booted:
            return ""
        started = "UEFI" if booted == "uefi" else "legacy BIOS"
        return (f"This machine started with {started}; "
                "it may not start the installed system the other way.")

    def erased(self):
        """The disks the page would erase."""
        names = list(self.selected) if self.mode == "erase" else []
        names += list(self.data_disks)
        if self.mode == "erase" and self.usage == "separate":
            names += [n for n, m in self.separate.items() if m]
        if self.mode == "manual":
            names += sorted({p["disk"] for p in self.partitions})
        return names

    def plan(self):
        """The disk plan of what the page shows."""
        plan = {"version": 1, "mode": self.mode,
                "boot": self.boot_combo.get_active_id() or "uefi",
                "filesystem": self.fs_combo.get_active_id(),
                "encryption": {"enabled": self.enc_check.get_active(),
                               "swap": self.swap_enc.get_active() and self.swap.get_value() > 0},
                "swap_mb": int(self.swap.get_value()) * 1024,
                "sector_4k": self.sector_4k.get_active(), "trim": self.trim.get_active(),
                "wipe": {n: w for n, w in self.wipe.items() if n in self.erased()},
                "confirm_foreign": list(self.wiz.confirm_foreign)}
        if self.mode == "erase" and self.asks_usage() and self.usage == "separate":
            plan.update(D.separate_plan(self.selected[0] if self.selected else "",
                                        self.separate, plan["filesystem"]))
            plan["wipe"] = {n: w for n, w in self.wipe.items() if n in self.erased()}
            return plan
        self.plan_mode(plan)
        if self.data_disks:
            plan["data"] = [{"name": "data", "disks": list(self.data_disks),
                             "layout": self.data_layout.get_active_id() or "single",
                             "filesystem": plan["filesystem"],
                             "mount": self.data_mount.get_text().strip() or DATA_MOUNT}]
        return plan

    def plan_mode(self, plan):
        """The part of the plan that depends on the mode."""
        if self.mode == "erase":
            plan["disks"] = list(self.selected)
            plan["layout"] = self.layout
            if self.asks_usage() and self.usage:
                plan["usage"] = self.usage
        elif self.mode == "alongside":
            index = self.region_combo.get_active()
            if 0 <= index < len(self.regions):
                name, free = self.regions[index]
                plan["alongside"] = {"disk": name, "region": {
                    "start_mb": free["start_mb"], "size_mb": int(self.size_scale.get_value()) * 1024}}
            plan["disks"] = []
        else:
            plan["partitions"] = [dict(p) for p in self.partitions]
            plan["disks"] = []

    def refresh_bars(self):
        for child in self.bars.get_children():
            self.bars.remove(child)
        plan = self.plan()
        index = D.disk_index(self.detail)
        shown = []
        if self.mode == "erase":
            shown = list(self.selected)
        elif self.mode == "alongside" and plan.get("alongside"):
            shown = [plan["alongside"]["disk"]]
        elif self.mode == "manual":
            shown = sorted({p["disk"] for p in self.partitions}) or list(index)[:1]
        shown += [n for n in self.data_disks if n not in shown]
        if self.mode == "erase" and self.usage == "separate":
            shown += [n for n, m in sorted(self.separate.items()) if m and n not in shown]
        for name in shown:
            disk = index.get(name)
            if not disk:
                continue
            grid = Gtk.Grid(column_spacing=10, row_spacing=2)
            grid.attach(lbl(f"{name}  {disk.get('model', '')}", "bar-caption", wrap=False), 0, 0, 2, 1)
            grid.attach(lbl("now", "bar-caption", wrap=False), 0, 1, 1, 1)
            grid.attach(bar(D.bar_before(disk)), 1, 1, 1, 1)
            grid.attach(lbl("after", "bar-caption", wrap=False), 0, 2, 1, 1)
            grid.attach(bar(D.bar_after(disk, plan, self.os, self.wiz.product)), 1, 2, 1, 1)
            self.bars.pack_start(grid, False, False, 0)
        if not shown:
            self.bars.pack_start(lbl("Choose a disk.", "muted"), False, False, 0)
        self.bars.show_all()

    def refresh_problems(self):
        if self.asks_usage() and self.usage is None:
            self.errors = ["Choose whether to use the disks together or separately."]
            self.problems.set_text("")
            self.warnings.set_text("")
            return
        errors = [e for e in D.validate(self.plan(), self.detail, self.os)
                  if "typed confirmation" not in e]
        if self.mode == "erase" and self.enc_check.get_active():
            errors += self.passphrase_errors()
        self.errors = errors
        self.problems.set_text("\n".join(errors))
        self.warnings.set_text("\n".join(self.erase_warnings()))

    def passphrase_errors(self):
        """What is wrong with the encryption passphrase: one problem or none."""
        if not self.pass1.get_text():
            return ["type a passphrase for the encryption"]
        if self.pass1.get_text() != self.pass2.get_text():
            return ["the passphrases do not match"]
        if D.passphrase_strength(self.pass1.get_text())[0] < 1:
            return ["the passphrase is too short (at least 8 characters)"]
        return []

    def erase_warnings(self):
        """The warnings about the disks the plan erases."""
        warnings = []
        index = D.disk_index(self.detail)
        erased = list(self.selected) if self.mode == "erase" else []
        erased += list(self.data_disks)
        if self.mode == "manual":
            erased += sorted({p["disk"] for p in self.partitions})
        for name in erased:
            found = D.foreign(index.get(name, {}))
            if found:
                warnings.append(f"{name} holds {', '.join(found)}: everything on it is deleted. "
                                "The summary asks you to confirm it by typing.")
        for name in erased:
            status = index.get(name, {}).get("health", {}).get("status")
            if status in ("warning", "failing"):
                warnings.append(f"{name} reports a health problem "
                                f"({index[name]['health'].get('summary', status)}).")
        for name, how in self.wipe.items():
            if how == "secure" and name in self.erased():
                warnings.append(f"{name} is securely erased when the installation starts; "
                                "this takes a long time.")
        return warnings

    def collect(self):
        """The check of the page when it is left with Next."""
        self.refresh_problems()
        if self.errors:
            return self.errors[0]
        self.wiz.set_disk_plan(self.plan(), self.detail,
                               self.pass1.get_text() if self.enc_check.get_active() else "")
        return None


def glib_escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

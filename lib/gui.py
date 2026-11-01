# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""installer-gui: the graphical front end of the installer.

A full-screen GTK 3 wizard with the pages of the text front end:
Welcome, Keyboard, Time zone, Disk, Users, Network, Summary, Installing and
Finished.  It drives the same backend, the same gating and the same answers
as bin/installer-tui; every decision is made in lib/wizard.py, which is
tested without a display.

Usage: installer-gui [--windowed] [--check] [--smoke FILE] [--screenshots DIR]

  --windowed         a window instead of the full screen
  --check            exit 0 when GTK can start, 3 when it cannot
  --smoke FILE       walk every page with the answers of a JSON file (the
                     password is read from standard input), install, and
                     exit with the result; for the test suite
  --screenshots DIR  with --smoke: write a PNG of every page to DIR
  --size WxH         with --screenshots: the size of the pages (1024x768)
  --text-scale F     with --smoke: text F times larger

Exit codes: 0 done, 1 the installation failed or was stopped, 3 no
graphical front end and no text fallback, 10 "Try the live desktop".

When GTK cannot start, the text front end is run in a terminal (xterm, or
xfce4-terminal), or on the terminal the program was started from.
"""

import os
import sys

ARGS = sys.argv[1:]

# The graphical front end runs as the user of the session, never as root:
# GTK loads modules and settings that the user of the display controls.
# Only the root helper (installer-apply) runs as root.  The check comes
# before anything but os and sys is imported.
if os.geteuid() == 0:
    if "--smoke" in ARGS or "--screenshots" in ARGS:
        sys.stderr.write("installer-gui: --smoke and --screenshots are refused for root\n")
        sys.exit(2)
    sys.stderr.write("installer-gui: the graphical installer does not run as root; "
                     "run it as the user of the session, or run installer-tui\n")
    sys.exit(3)

# bin/installer-gui runs this file with python3 -I: the directory of the
# script and the current directory are not on sys.path, so the library is
# named by its own place.
HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.environ.get("INSTALLER_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, HERE)

import wizard as W  # noqa: E402


def fallback_tui(reason: str) -> int:
    """GTK cannot start: run the text front end where it can be seen."""
    tui = os.path.join(ROOT, "bin", "installer-tui")
    sys.stderr.write(f"installer-gui: {reason}; using the text front end\n")
    terminal = W.find_terminal() if os.environ.get("DISPLAY") else None
    if terminal:
        import subprocess
        import tempfile
        status_dir = tempfile.mkdtemp(prefix="wtfbsd-tui.")
        status = os.path.join(status_dir, "rc")
        script = '"$1"; echo $? > "$2"'
        name = os.path.basename(terminal)
        if name == "xterm":
            argv = [terminal, "-maximized", "-title", "Installer", "-e",
                    "sh", "-c", script, "sh", tui, status]
        else:
            argv = [terminal, "--fullscreen", "-x", "sh", "-c", script, "sh", tui, status]
        subprocess.call(argv)
        try:
            with open(status, encoding="ascii") as stream:
                code = int(stream.read().strip() or "1")
        except (OSError, ValueError):
            code = 1
        import shutil
        shutil.rmtree(status_dir, ignore_errors=True)
        return code
    if sys.stdin.isatty():
        os.execv(tui, [tui])
    sys.stderr.write("installer-gui: no terminal program (xterm, xfce4-terminal) "
                     "and no terminal to run the text front end on\n")
    return W.EXIT_NO_GUI


try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402
    try:
        # The accessible relations of a field and its label (ATK comes with
        # GTK 3; without it the mnemonic still links them).
        gi.require_version("Atk", "1.0")
        from gi.repository import Atk  # noqa: E402
    except (ImportError, ValueError):
        Atk = None
    GTK_OK, GTK_REASON = Gtk.init_check(sys.argv)[0], "GTK cannot open the display"
except (ImportError, ValueError) as error:
    GTK_OK, GTK_REASON = False, f"GTK 3 for Python is not available ({error})"

if "--check" in ARGS:
    sys.exit(0 if GTK_OK else W.EXIT_NO_GUI)
if not GTK_OK:
    sys.exit(fallback_tui(GTK_REASON))

CSS = b"""
.sidebar { background-color: #1f2430; }
.sidebar label { color: #c8ccd4; }
.sidebar .product { color: #ffffff; font-size: 20px; font-weight: bold; }
.sidebar .step { padding: 6px 18px; font-size: 14px; }
.sidebar .step-current { color: #ffffff; font-weight: bold;
    border-left: 4px solid #4c8bf5; padding-left: 14px; }
.sidebar .step-done { color: #8fbf7f; }
.page-title { font-size: 26px; font-weight: bold; }
.lead { font-size: 15px; }
.lead-big { font-size: 20px; }
.error-text { color: #c01c28; }
.warning-text { color: #a05a00; font-weight: bold; }
.action-bar { padding: 12px 18px; border-top: 1px solid alpha(#000000, 0.12); }
.action-bar button { min-width: 120px; min-height: 36px; }
.field-label { font-weight: bold; }
"""

PAGE_TITLES = dict(W.PAGES)


def label(text="", css=None, wrap=True, xalign=0.0, selectable=False):
    widget = Gtk.Label(label=text)
    widget.set_xalign(xalign)
    widget.set_line_wrap(wrap)
    widget.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    widget.set_selectable(selectable)
    if css:
        for name in css.split():
            widget.get_style_context().add_class(name)
    return widget


def field_label(text, control):
    """The label of a field, linked to its control: the underlined letter
    of the text (Alt and the letter) moves the focus to the control, and a
    screen reader announces the label when the control has the focus (the
    labelled-by relation of the control, label-for of the label)."""
    widget = label("", "field-label")
    widget.set_text_with_mnemonic(text)
    widget.set_mnemonic_widget(control)
    if Atk is not None:
        own = widget.get_accessible()
        other = control.get_accessible()
        own.add_relationship(Atk.RelationType.LABEL_FOR, other)
        other.add_relationship(Atk.RelationType.LABELLED_BY, own)
    return widget


def labelled_by(control):
    """The texts of the labels a control is labelled by (for the checks)."""
    if Atk is None:
        return [w.get_text() for w in control.list_mnemonic_labels()]
    relations = control.get_accessible().ref_relation_set()
    relation = relations.get_relation_by_type(Atk.RelationType.LABELLED_BY)
    if relation is None:
        return []
    return [target.get_name() for target in relation.get_target()]


def monitor_size():
    """The size of the work area of the monitor, 1024x768 when it cannot be
    read."""
    display = Gdk.Display.get_default()
    monitor = display.get_primary_monitor() if display else None
    if monitor is None and display is not None and display.get_n_monitors() > 0:
        monitor = display.get_monitor(0)
    if monitor is None:
        return 1024, 768
    area = monitor.get_workarea()
    return max(area.width, 640), max(area.height, 480)


def item_list(columns, activate=None):
    """A list of rows: a ListStore, its view and its scroller."""
    store = Gtk.ListStore(*([str] * len(columns)))
    view = Gtk.TreeView(model=store)
    view.set_headers_visible(True)
    for index, title in enumerate(columns):
        renderer = Gtk.CellRendererText()
        if index == 1:
            renderer.set_property("ellipsize", Pango.EllipsizeMode.END)
        column = Gtk.TreeViewColumn(title, renderer, text=index)
        column.set_expand(index == 1)
        view.append_column(column)
    if activate:
        view.connect("row-activated", lambda *_a: activate())
    scroller = Gtk.ScrolledWindow()
    scroller.set_vexpand(True)
    scroller.set_min_content_height(150)
    scroller.set_shadow_type(Gtk.ShadowType.IN)
    scroller.add(view)
    return store, view, scroller


def selected_name(view):
    model, it = view.get_selection().get_selected()
    return model[it][0] if it is not None else ""


def select_name(view, name):
    model = view.get_model()
    for row in model:
        if row[0] == name:
            view.get_selection().select_iter(row.iter)
            view.scroll_to_cell(row.path, None, False, 0, 0)
            return True
    if len(model):
        view.get_selection().select_path(Gtk.TreePath.new_first())
    return False


class InstallerWindow(Gtk.Window):
    def __init__(self, wiz, windowed=False, offscreen=False, size=None):
        super().__init__(title=f"{wiz.product} Installer")
        self.wiz = wiz
        self.result = W.EXIT_OK
        self.page = "welcome"
        self.failure = None
        self.failures = []
        self.run = None
        self.running = False
        # The window follows the monitor: no size above the smallest screen
        # the installer supports (1024x768) is ever asked for, and the
        # content of a page scrolls, so the buttons are always on screen.
        width, height = monitor_size()
        self.set_default_size(min(width, 1280), min(height, 900))
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.connect("delete-event", self.on_delete)
        self.connect("key-press-event", self.on_key)

        outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        # The smoke run draws the pages in an offscreen window, so that a
        # picture of every page can be taken on any display backend.
        self.offscreen = None
        if offscreen:
            self.offscreen = Gtk.OffscreenWindow()
            width, height = size or (1024, 768)
            self.offscreen.set_size_request(width, height)
            self.offscreen.add(outer)
        else:
            self.add(outer)
        outer.pack_start(self.build_sidebar(), False, False, 0)
        main = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.pack_start(main, True, True, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        body.set_border_width(32)
        main.pack_start(body, True, True, 0)
        self.title_label = label("", "page-title")
        body.pack_start(self.title_label, False, False, 0)
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        # The content of the page scrolls; the title above it and the action
        # cluster below it stay where they are.
        self.page_scroller = Gtk.ScrolledWindow()
        self.page_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.page_scroller.set_vexpand(True)
        self.page_scroller.add(self.stack)
        body.pack_start(self.page_scroller, True, True, 0)
        self.error_label = label("", "error-text", selectable=True)
        body.pack_start(self.error_label, False, False, 0)
        # The one action cluster, at the bottom right.
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        bar.get_style_context().add_class("action-bar")
        self.actions_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.actions_box.set_halign(Gtk.Align.END)
        bar.pack_end(self.actions_box, False, False, 0)
        main.pack_end(bar, False, False, 0)

        self.builders = {
            "preflight": self.page_preflight, "welcome": self.page_welcome,
            "keyboard": self.page_keyboard, "timezone": self.page_timezone,
            "disk": self.page_disk, "users": self.page_users,
            "network": self.page_network, "summary": self.page_summary,
            "install": self.page_install, "finish": self.page_finish,
        }
        for name, build in self.builders.items():
            self.stack.add_named(build(), name)
        if windowed:
            self.set_position(Gtk.WindowPosition.CENTER)
        else:
            self.fullscreen()

    # ------------------------------------------------------------ frame

    def build_sidebar(self):
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        side.get_style_context().add_class("sidebar")
        side.set_size_request(240, -1)
        head = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        head.set_border_width(18)
        if self.wiz.logo:
            try:
                pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(self.wiz.logo, 160, 96, True)
                head.pack_start(Gtk.Image.new_from_pixbuf(pix), False, False, 0)
            except GLib.Error:
                pass
        head.pack_start(label(self.wiz.product, "product"), False, False, 0)
        side.pack_start(head, False, False, 0)
        self.step_labels = {}
        for ident, title in W.PAGES:
            widget = label(title, "step", wrap=False)
            self.step_labels[ident] = widget
            side.pack_start(widget, False, False, 0)
        return side

    def mark_steps(self):
        current = W.PAGE_IDS.index(self.page) if self.page in W.PAGE_IDS else -1
        for index, ident in enumerate(W.PAGE_IDS):
            ctx = self.step_labels[ident].get_style_context()
            ctx.remove_class("step-current")
            ctx.remove_class("step-done")
            if index == current:
                ctx.add_class("step-current")
            elif index < current:
                ctx.add_class("step-done")

    def set_actions(self):
        for child in self.actions_box.get_children():
            self.actions_box.remove(child)
        self.buttons = {}
        acts = self.wiz.actions(self.page, failed=self.wiz.install_failed and not self.running,
                                running=self.running, failure=self.failure)
        primary = None
        for act in acts:
            button = Gtk.Button(label=act.label)
            ctx = button.get_style_context()
            if act.primary:
                ctx.add_class("destructive-action" if act.destructive else "suggested-action")
                button.set_can_default(True)
                primary = button
            button.connect("clicked", self.on_action, act.ident)
            self.actions_box.pack_start(button, False, False, 0)
            self.buttons[act.ident] = button
        self.actions_box.show_all()
        if primary is not None:
            primary.grab_default()
        self.refresh_sensitivity()

    def refresh_sensitivity(self):
        button = self.buttons.get("next")
        if button is None:
            return
        if self.page == "disk":
            button.set_sensitive(bool(selected_name(self.disk_view)))
        elif self.page in ("keyboard", "timezone"):
            view = self.kb_view if self.page == "keyboard" else self.tz_view
            button.set_sensitive(bool(selected_name(view)))
        else:
            button.set_sensitive(True)

    def show_page(self, page):
        self.page = page
        self.error_label.set_text("")
        if page == "preflight":
            self.title_label.set_text("Unfortunately")
        else:
            self.title_label.set_text(PAGE_TITLES.get(page, page))
        enter = getattr(self, f"enter_{page}", None)
        if enter:
            enter()
        self.stack.set_visible_child_name(page)
        self.mark_steps()
        self.set_actions()

    def show_error(self, text):
        self.error_label.set_text(text or "")

    # ------------------------------------------------------------ events

    def on_action(self, _button, ident):
        handler = getattr(self, "act_" + ident.replace("-", "_"))
        handler()

    def act_back(self):
        if self.page == "install":
            self.wiz.install_failed = False
            self.show_page("summary")
            return
        self.show_page(W.Wizard.prev_page(self.page))

    def act_next(self):
        collect = getattr(self, f"collect_{self.page}", None)
        if collect is not None:
            problem = collect()
            if problem:
                self.show_error(problem)
                return
        problem = self.wiz.leave(self.page)
        if problem:
            self.show_error(problem)
            return
        self.show_page(W.Wizard.next_page(self.page))

    def act_try_live(self):
        self.result = W.EXIT_TRY_LIVE
        self.quit()

    def act_quit(self):
        self.quit()

    def act_rescan(self):
        self.start()

    def act_override(self):
        if self.ask("The requirement is not met.", "Continue anyway?",
                    "Cancel", "Continue") != "right":
            return
        self.wiz.override(self.failure)
        self.failures = [f for f in self.failures if f is not self.failure]
        self.next_failure()

    def act_install(self):
        self.show_page("install")
        self.begin_install()

    def act_retry(self):
        self.begin_install()

    def act_stop(self):
        if self.ask("Stop the installation?",
                    "The disk is left in a state that does not boot.",
                    "Stop", "Continue the installation", left_destructive=True) == "left":
            if self.run is not None:
                self.run.stop()
                GLib.timeout_add_seconds(10, self.kill_if_running)

    def act_stay(self):
        self.quit()

    def act_reboot(self):
        # The root helper reboots (installer-apply --reboot).
        argv = self.wiz.reboot_command()
        import subprocess
        try:
            subprocess.Popen(argv)
        except OSError as error:
            self.show_error(f"Cannot reboot: {error}")
            return
        self.quit()

    def kill_if_running(self):
        if self.run is not None and self.running:
            self.run.kill()
        return False

    def on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.request_close()
            return True
        return False

    def request_close(self):
        """The close button or the escape key: a running installation is
        stopped; otherwise the installer asks, and quits on Quit."""
        if self.running:
            self.act_stop()
            return
        if self.page == "finish" or self.ask(
                "Quit the installer?", "Nothing has been installed yet." if not
                self.wiz.installed else f"{self.wiz.product} is installed.",
                "Quit", "Continue") == "left":
            if self.page != "finish":
                self.result = W.EXIT_FAILED if self.wiz.install_failed else W.EXIT_OK
            self.quit()

    def on_delete(self, *_args):
        # GTK never destroys the window by itself: request_close decides,
        # and quit() ends the installer.
        self.request_close()
        return True

    def ask(self, primary, secondary, left, right, left_destructive=False):
        """A question with two buttons.  The right one is the default and
        it is always the safe one, so a stray Enter never destroys
        anything.  Returns "left" or "right"."""
        dialog = Gtk.MessageDialog(transient_for=self, modal=True,
                                   message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text=primary)
        dialog.format_secondary_text(secondary)
        left_button = dialog.add_button(left, Gtk.ResponseType.NO)
        if left_destructive:
            left_button.get_style_context().add_class("destructive-action")
        right_button = dialog.add_button(right, Gtk.ResponseType.YES)
        right_button.get_style_context().add_class("suggested-action")
        dialog.set_default_response(Gtk.ResponseType.YES)
        right_button.grab_focus()
        answer = dialog.run()
        dialog.destroy()
        return "left" if answer == Gtk.ResponseType.NO else "right"

    def quit(self):
        if self.run is not None and self.running:
            self.run.stop()
        Gtk.main_quit()

    # ------------------------------------------------------------ start

    def start(self):
        """The checks before the first page."""
        self.failures = self.wiz.preflight()
        self.next_failure()

    def next_failure(self):
        if self.failures:
            self.failure = self.failures[0]
            self.show_page("preflight")
            return
        self.failure = None
        self.show_page("welcome")

    # ------------------------------------------------------------ pages

    def page_preflight(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.pf_text = label("", "lead")
        grid = Gtk.Grid(column_spacing=18, row_spacing=8)
        self.pf_values = {}
        for row, name in enumerate(("Requirement", "Detected", "Needed")):
            grid.attach(label(name + ":", "field-label"), 0, row, 1, 1)
            value = label("", selectable=True)
            grid.attach(value, 1, row, 1, 1)
            self.pf_values[name] = value
        self.pf_hint = label("")
        box.pack_start(self.pf_text, False, False, 0)
        box.pack_start(grid, False, False, 0)
        box.pack_start(self.pf_hint, False, False, 0)
        return box

    def enter_preflight(self):
        f = self.failure
        self.pf_text.set_text("This machine does not meet a requirement of the installer.")
        self.pf_values["Requirement"].set_text(f.requirement)
        self.pf_values["Detected"].set_text(f.detected + (f" ({f.detail})" if f.detail else ""))
        self.pf_values["Needed"].set_text(f.needed)
        hint = "Choose Rescan to look for the hardware again"
        if f.may_override:
            hint += ", Override to continue without the requirement"
        hint += ", or Quit to leave the installer and stay in the live system."
        self.pf_hint.set_text(hint)

    def page_welcome(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER)
        product = self.wiz.product
        box.pack_start(label(f"{product} is ready to be installed.", "lead-big"), False, False, 0)
        box.pack_start(label(
            f"This installer will guide you through installing {product} on this "
            "machine. It asks for the keyboard, the time zone, the disk, your "
            "account and the network, shows a summary, and changes nothing "
            "before you choose Install.", "lead"), False, False, 0)
        box.pack_start(label(
            "Choose Try the live desktop to use the system without installing it. "
            f"The Install {product} icon on the desktop brings the installer back."),
            False, False, 0)
        return box

    def page_keyboard(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(label("Choose the keyboard layout of the installed system."), False, False, 0)
        self.kb_store, self.kb_view, scroller = item_list(("Layout", "Country"), self.act_next)
        self.kb_view.get_selection().connect("changed", self.on_keymap_changed)
        box.pack_start(scroller, True, True, 0)
        test = Gtk.Entry()
        test.set_placeholder_text("Type here to test the keyboard")
        box.pack_start(test, False, False, 0)
        return box

    def on_keymap_changed(self, *_args):
        """The live X session types in the layout that is picked, at once,
        so the test field and the password fields use it."""
        self.refresh_sensitivity()
        name = selected_name(self.kb_view)
        if name and name != self.wiz.applied_keymap:
            self.wiz.log(self.wiz.apply_keymap(name))

    def enter_keyboard(self):
        if not len(self.kb_store):
            for item in self.wiz.keymaps():
                self.kb_store.append([item.name, item.descr])
        select_name(self.kb_view, self.wiz.answers.keymap)

    def collect_keyboard(self):
        name = selected_name(self.kb_view)
        if not name:
            return "Choose a keyboard layout."
        self.wiz.answers.keymap = name
        return None

    def page_timezone(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(label("Choose the time zone of the installed system."), False, False, 0)
        self.tz_search = Gtk.SearchEntry()
        self.tz_search.set_placeholder_text("Search, for example Berlin or New_York")
        box.pack_start(self.tz_search, False, False, 0)
        self.tz_store, self.tz_view, scroller = item_list(("Time zone", "Region"), self.act_next)
        self.tz_filter = self.tz_store.filter_new()
        self.tz_filter.set_visible_func(self.tz_visible)
        self.tz_view.set_model(self.tz_filter)
        self.tz_view.get_selection().connect("changed", lambda *_a: self.refresh_sensitivity())
        self.tz_search.connect("search-changed", lambda *_a: self.tz_filter.refilter())
        box.pack_start(scroller, True, True, 0)
        return box

    def tz_visible(self, model, it, _data):
        text = self.tz_search.get_text().strip().lower().replace(" ", "_")
        return not text or text in (model[it][0] + " " + model[it][1]).lower().replace(" ", "_")

    def enter_timezone(self):
        if not len(self.tz_store):
            for item in self.wiz.zones():
                self.tz_store.append([item.name, item.descr])
        select_name(self.tz_view, self.wiz.answers.timezone)

    def collect_timezone(self):
        name = selected_name(self.tz_view)
        if not name:
            return "Choose a time zone."
        self.wiz.answers.timezone = name
        return None

    def page_disk(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.disk_text = label("")
        box.pack_start(self.disk_text, False, False, 0)
        self.disk_store, self.disk_view, scroller = item_list(("Disk", "Model", "Size"))
        self.disk_view.get_selection().connect("changed", lambda *_a: self.refresh_sensitivity())
        box.pack_start(scroller, True, True, 0)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        rescan = Gtk.Button(label="Look for disks again")
        rescan.connect("clicked", lambda *_a: self.enter_disk())
        row.pack_start(rescan, False, False, 0)
        box.pack_start(row, False, False, 0)
        box.pack_start(label("Everything on the chosen disk will be erased.", "warning-text"),
                       False, False, 0)
        return box

    def enter_disk(self):
        self.disks, err = self.wiz.disks()
        self.disk_store.clear()
        for item in self.disks:
            self.disk_store.append([item.name, item.descr, W.human_size(item.size_bytes)])
        if self.disks:
            self.disk_text.set_text(f"Choose the disk to install {self.wiz.product} to.")
            select_name(self.disk_view, self.wiz.answers.disk)
        else:
            self.disk_text.set_text(
                "No disks found. The installer looked for a disk to write to and did "
                "not find one." + (f" ({err})" if err else ""))
        self.refresh_sensitivity()

    def collect_disk(self):
        name = selected_name(self.disk_view)
        if not name:
            return "Choose a disk."
        for item in self.disks:
            if item.name == name:
                a = self.wiz.answers
                a.disk, a.disk_descr, a.disk_size = item.name, item.descr, item.size_bytes
        return None

    def page_users(self):
        grid = Gtk.Grid(column_spacing=16, row_spacing=6)
        self.user_entries = {}
        self.user_errors = {}
        # The underlined letter of each label (Alt and the letter) is the
        # only one of that letter on the page.
        fields = [
            ("full_name", "_Full name", False, "optional"),
            ("user_name", "_User name", False, "for example alice"),
            ("password", "_Password", True, ""),
            ("confirm", "C_onfirm the password", True, ""),
            ("hostname", "_Host name", False, "the name of this machine"),
        ]
        row = 0
        for key, text, secret, hint in fields:
            entry = Gtk.Entry()
            grid.attach(field_label(text, entry), 0, row, 1, 1)
            entry.set_hexpand(True)
            entry.set_activates_default(True)
            entry.set_placeholder_text(hint)
            if secret:
                entry.set_visibility(False)
                entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            grid.attach(entry, 1, row, 1, 1)
            error = label("", "error-text")
            grid.attach(error, 1, row + 1, 1, 1)
            self.user_entries[key] = entry
            self.user_errors[key] = error
            row += 2
        self.user_entries["user_name"].set_max_length(32)
        self.ssh_view = Gtk.TextView()
        grid.attach(field_label("_SSH public key", self.ssh_view), 0, row, 1, 1)
        self.ssh_view.set_wrap_mode(Gtk.WrapMode.CHAR)
        self.ssh_view.set_monospace(True)
        scroller = Gtk.ScrolledWindow()
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.set_size_request(-1, 70)
        scroller.add(self.ssh_view)
        grid.attach(scroller, 1, row, 1, 1)
        self.user_errors["ssh_key"] = label("", "error-text")
        grid.attach(label("Optional: paste a public key (ssh-ed25519 ...) to log in with it.",
                          None), 1, row + 1, 1, 1)
        grid.attach(self.user_errors["ssh_key"], 1, row + 2, 1, 1)
        row += 3
        self.priv_check = Gtk.CheckButton(label="Passwordless sudo and doas for this account")
        grid.attach(self.priv_check, 1, row, 1, 1)
        return grid

    def enter_users(self):
        a = self.wiz.answers
        self.user_entries["full_name"].set_text(a.full_name)
        self.user_entries["user_name"].set_text(a.user_name)
        self.user_entries["hostname"].set_text(a.hostname)
        self.ssh_view.get_buffer().set_text(a.ssh_key)
        self.priv_check.set_active(a.privilege_passwordless)
        self.user_entries["full_name"].grab_focus()

    def collect_users(self):
        get = {k: e.get_text() for k, e in self.user_entries.items()}
        buf = self.ssh_view.get_buffer()
        ssh_key = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        errors = self.wiz.check_users(get["user_name"], get["full_name"], get["password"],
                                      get["confirm"], get["hostname"], ssh_key)
        for key, widget in self.user_errors.items():
            widget.set_text(errors.get(key, ""))
        if errors:
            return "Some fields need attention."
        a = self.wiz.answers
        a.user_name, a.full_name, a.hostname = get["user_name"], get["full_name"], get["hostname"]
        a.ssh_key = ssh_key
        a.privilege_passwordless = self.priv_check.get_active()
        try:
            # nosemgrep: python.django.security.audit.unvalidated-password.unvalidated-password -- not Django; checked by Wizard.check_users above (not empty, matches the confirmation) and refused again by passhash.make_hash before it is hashed
            self.wiz.set_password(get["password"])
        except (W.passhash.HashError, OSError) as error:
            return f"The password cannot be stored: {error}"
        return None

    def page_network(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.net_text = label("")
        box.pack_start(self.net_text, False, False, 0)
        self.net_store, self.net_view, scroller = item_list(("Adapter", "Description"))
        scroller.set_size_request(-1, 140)
        box.pack_start(scroller, True, True, 0)
        rescan = Gtk.Button(label="Look for adapters again")
        rescan.set_halign(Gtk.Align.START)
        rescan.connect("clicked", lambda *_a: self.enter_network())
        box.pack_start(rescan, False, False, 0)
        self.mode_dhcp = Gtk.RadioButton.new_with_label(None, "Automatic address (DHCP)")
        self.mode_static = Gtk.RadioButton.new_with_label_from_widget(self.mode_dhcp, "Manual address")
        self.mode_offline = Gtk.RadioButton.new_with_label_from_widget(
            self.mode_dhcp, "No network: install the system offline")
        for radio in (self.mode_dhcp, self.mode_static, self.mode_offline):
            radio.connect("toggled", lambda *_a: self.net_gate())
            box.pack_start(radio, False, False, 0)
        grid = Gtk.Grid(column_spacing=16, row_spacing=6)
        grid.set_margin_start(28)
        self.net_entries = {}
        for row, (key, text) in enumerate((("ipv4_addr", "_Address"), ("ipv4_mask", "Net_mask"),
                                           ("ipv4_gw", "_Gateway"))):
            entry = Gtk.Entry()
            grid.attach(field_label(text, entry), 0, row, 1, 1)
            entry.set_activates_default(True)
            entry.set_placeholder_text("for example 192.0.2.10" if key == "ipv4_addr" else "")
            grid.attach(entry, 1, row, 1, 1)
            self.net_entries[key] = entry
        box.pack_start(grid, False, False, 0)
        return box

    def net_gate(self):
        """A manual address is only typeable while Manual is chosen; what
        was typed stays in the fields."""
        static = self.mode_static.get_active()
        for entry in self.net_entries.values():
            entry.set_sensitive(static)
        self.net_view.set_sensitive(not self.mode_offline.get_active())

    def enter_network(self):
        self.nets, err = self.wiz.interfaces()
        self.net_store.clear()
        for item in self.nets:
            self.net_store.append([item.name, item.descr])
        a = self.wiz.answers
        if self.nets:
            self.net_text.set_text(f"Choose how {self.wiz.product} is connected.")
            select_name(self.net_view, a.net_if)
            self.mode_dhcp.set_sensitive(True)
            self.mode_static.set_sensitive(True)
        else:
            self.net_text.set_text("No network adapters found. The installation can "
                                   "continue without a network." + (f" ({err})" if err else ""))
            a.network_mode = "offline"
            self.mode_dhcp.set_sensitive(False)
            self.mode_static.set_sensitive(False)
        {"dhcp": self.mode_dhcp, "static": self.mode_static,
         "offline": self.mode_offline}[a.network_mode].set_active(True)
        for key, entry in self.net_entries.items():
            entry.set_text(getattr(a, key))
        self.net_gate()

    def collect_network(self):
        a = self.wiz.answers
        if self.mode_offline.get_active():
            a.network_mode, a.net_if = "offline", ""
            return None
        name = selected_name(self.net_view)
        if not name:
            return "Choose a network adapter, or choose No network."
        a.net_if = name
        if self.mode_static.get_active():
            values = {k: e.get_text().strip() for k, e in self.net_entries.items()}
            for key, text in (("ipv4_addr", "address"), ("ipv4_mask", "netmask")):
                if not W.ipv4_valid(values[key]):
                    return f"The {text} is not an IPv4 address."
            if values["ipv4_gw"] and not W.ipv4_valid(values["ipv4_gw"]):
                return "The gateway is not an IPv4 address."
            a.network_mode = "static"
            a.ipv4_addr, a.ipv4_mask, a.ipv4_gw = (values["ipv4_addr"], values["ipv4_mask"],
                                                   values["ipv4_gw"])
        else:
            a.network_mode = "dhcp"
        return None

    def page_summary(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.pack_start(label("The installation will use:"), False, False, 0)
        self.sum_grid = Gtk.Grid(column_spacing=24, row_spacing=6)
        box.pack_start(self.sum_grid, False, False, 0)
        self.sum_warning = label("", "warning-text")
        box.pack_start(self.sum_warning, False, False, 0)
        box.pack_start(label(f"Choose Install to install {self.wiz.product} with these "
                             "settings."), False, False, 0)
        return box

    def enter_summary(self):
        for child in self.sum_grid.get_children():
            self.sum_grid.remove(child)
        for row, (name, value) in enumerate(self.wiz.summary_rows()):
            self.sum_grid.attach(label(name, "field-label"), 0, row, 1, 1)
            self.sum_grid.attach(label(value), 1, row, 1, 1)
        self.sum_grid.show_all()
        self.sum_warning.set_text(self.wiz.erase_warning())

    def page_install(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.inst_step = label(f"Installing {self.wiz.product}.", "lead")
        box.pack_start(self.inst_step, False, False, 0)
        self.inst_bar = Gtk.ProgressBar()
        self.inst_bar.set_show_text(True)
        box.pack_start(self.inst_bar, False, False, 0)
        self.inst_result = label("")
        box.pack_start(self.inst_result, False, False, 0)
        expander = Gtk.Expander(label="Details")
        expander.set_expanded(False)
        self.inst_log = Gtk.TextView()
        self.inst_log.set_editable(False)
        self.inst_log.set_monospace(True)
        self.inst_log.set_cursor_visible(False)
        scroller = Gtk.ScrolledWindow()
        scroller.set_vexpand(True)
        scroller.set_size_request(-1, 260)
        scroller.add(self.inst_log)
        expander.add(scroller)
        box.pack_start(expander, True, True, 0)
        self.inst_expander = expander
        return box

    def begin_install(self):
        self.wiz.install_failed = False
        self.inst_bar.set_fraction(0)
        self.inst_bar.set_text("0%")
        self.inst_result.set_text("")
        self.inst_log.get_buffer().set_text("")
        self.inst_step.set_text(f"Installing {self.wiz.product}.")
        if not self.wiz.hash_file:
            # The hash is removed after every run; a retry hashes the
            # password of the users page again.
            try:
                # nosemgrep: python.django.security.audit.unvalidated-password.unvalidated-password -- not Django; the users page passed Wizard.check_users before the summary, and passhash.make_hash refuses an empty password again
                self.wiz.set_password(self.user_entries["password"].get_text())
            except (W.passhash.HashError, OSError) as error:
                self.wiz.install_failed = True
                self.show_error(f"The password cannot be stored: {error}")
                self.set_actions()
                return
        self.run = W.InstallRun(self.wiz, self.on_progress, self.on_log, self.on_install_error)
        problem = self.run.start()
        if problem:
            self.wiz.install_failed = True
            self.show_error(problem)
            self.set_actions()
            return
        self.running = True
        self.set_actions()
        # The output is read from the descriptor itself, without a buffer
        # in between, so every line shows the moment it is written.
        self.out_fd = self.run.proc.stdout.fileno()
        os.set_blocking(self.out_fd, False)
        self.out_buf = b""
        GLib.io_add_watch(self.out_fd, GLib.PRIORITY_DEFAULT,
                          GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                          self.on_output)

    def on_output(self, _fd, _condition):
        try:
            chunk = os.read(self.out_fd, 65536)
        except BlockingIOError:
            return True
        except OSError:
            chunk = b""
        if chunk:
            self.out_buf += chunk
            *lines, self.out_buf = self.out_buf.split(b"\n")
            for line in lines:
                self.run.feed(line.decode("utf-8", "replace") + "\n")
            return True
        if self.out_buf:
            self.run.feed(self.out_buf.decode("utf-8", "replace") + "\n")
            self.out_buf = b""
        code = self.run.finish()
        self.running = False
        if code == 0:
            self.on_progress(100, "Done")
            self.show_page("finish")
        else:
            self.wiz.publish_log()
            stopped = "was stopped" if self.run.stopped else "did not finish"
            reason = self.run.errors[-1] if self.run.errors else ""
            self.inst_step.set_text(f"The installation {stopped}.")
            self.inst_result.set_text(
                (f"{reason}\n\n" if reason else "") +
                f"The details are in {self.wiz.log_destination}. Choose Retry to run the "
                "installation again, or Back to the summary to change the answers.")
            self.inst_expander.set_expanded(True)
            self.set_actions()
        return False

    def on_progress(self, percent, text):
        self.inst_bar.set_fraction(percent / 100.0)
        self.inst_bar.set_text(f"{percent}%")
        if text:
            self.inst_step.set_text(text)

    def on_log(self, line):
        buf = self.inst_log.get_buffer()
        buf.insert(buf.get_end_iter(), line + "\n")
        self.inst_log.scroll_to_iter(buf.get_end_iter(), 0, False, 0, 1)

    def on_install_error(self, text):
        self.inst_result.set_text(text)

    def page_finish(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER)
        box.pack_start(label(f"{self.wiz.product} is installed.", "page-title"), False, False, 0)
        box.pack_start(label("Remove the installation media and reboot. The installed "
                             "system starts with the login screen.", "lead"), False, False, 0)
        return box


# ---------------------------------------------------------------- smoke

def fields_of(win):
    """Every text field of the page that is shown (Gtk.Entry and
    Gtk.TextView), with the labels it is labelled by."""
    found = []
    page = win.stack.get_child_by_name(win.page)

    def walk(widget):
        if isinstance(widget, (Gtk.Entry, Gtk.TextView)):
            found.append({"kind": type(widget).__name__,
                          "labelled_by": labelled_by(widget)})
        if isinstance(widget, Gtk.Container):
            for child in widget.get_children():
                walk(child)
    if page is not None:
        walk(page)
    return found


def layout_of(win):
    """Where the buttons of the cluster and the title are, and their fonts,
    for the checks of the test suite."""
    top = win.offscreen or win
    width, height = top.get_allocated_width(), top.get_allocated_height()
    buttons = []
    for child in win.actions_box.get_children():
        x, y = child.translate_coordinates(top, 0, 0)
        alloc = child.get_allocation()
        ctx = child.get_style_context()
        buttons.append({
            "label": child.get_label(), "x": x, "y": y,
            "w": alloc.width, "h": alloc.height,
            "primary": ctx.has_class("suggested-action") or ctx.has_class("destructive-action"),
            "default": child.has_default(),
            "visible": child.get_visible() and child.get_mapped(),
        })
    title = win.title_label
    tx, ty = title.translate_coordinates(top, 0, 0)
    font = title.get_style_context().get_property("font", Gtk.StateFlags.NORMAL)
    dpi = Gtk.Settings.get_default().get_property("gtk-xft-dpi")
    dpi = dpi / 1024 if dpi and dpi > 0 else 96
    return {"page": win.page, "width": width, "height": height, "buttons": buttons,
            "fields": fields_of(win),
            "title": {"text": title.get_text(), "x": tx, "y": ty,
                      # The size in pixels: points at the resolution of the
                      # fonts (gtk-xft-dpi is in 1024ths of a dot per inch).
                      "font_px": font.get_size() / Pango.SCALE * dpi / 72,
                      "bold": font.get_weight() >= Pango.Weight.BOLD}}


class Smoke:
    """Walk every page with the given answers, the way a person would:
    the fields are filled and the buttons are clicked."""

    def __init__(self, win, answers, password, shots):
        self.win = win
        self.answers = answers
        self.password = password
        self.shots = shots
        self.seen = []
        self.layouts = []
        self.pages = {
            "preflight": self.page_preflight, "welcome": self.page_welcome,
            "keyboard": self.page_keyboard, "timezone": self.page_timezone,
            "disk": self.page_disk, "users": self.page_users,
            "network": self.page_network, "summary": self.page_summary,
            "install": self.page_install, "finish": self.page_finish,
        }

    @staticmethod
    def pump():
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)

    def shot(self):
        import time
        page = self.win.page
        for _ in range(6):
            self.pump()
            time.sleep(0.03)
        self.seen.append(page)
        self.layouts.append(layout_of(self.win))
        if self.shots:
            self.save_shot(page)

    def save_shot(self, page):
        pixbuf = self.win.offscreen.get_pixbuf() if self.win.offscreen else None
        if pixbuf is None:
            return
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        if ok:
            W.write_new_file(os.path.join(self.shots, f"{len(self.seen):02d}-{page}.png"),
                             data)

    def click(self, ident):
        win = self.win
        self.shot()
        button = win.buttons.get(ident)
        if button is None or not button.get_sensitive():
            raise SystemExit(f"smoke: no button {ident} on {win.page}: {list(win.buttons)}")
        button.clicked()
        self.pump()

    def page_preflight(self):
        win = self.win
        if win.failure and win.failure.may_override and self.answers.get("override"):
            win.wiz.override(win.failure)
            win.failures = [f for f in win.failures if f is not win.failure]
            win.next_failure()
            return None
        self.shot()
        raise SystemExit(f"smoke: stopped before the first page: {win.failure}")

    def page_welcome(self):
        self.click("next")

    def page_keyboard(self):
        select_name(self.win.kb_view, self.answers.get("keymap", ""))
        self.click("next")

    def page_timezone(self):
        select_name(self.win.tz_view, self.answers.get("timezone", ""))
        self.click("next")

    def page_disk(self):
        select_name(self.win.disk_view, self.answers.get("disk", ""))
        self.click("next")

    def page_users(self):
        answers = self.answers
        e = self.win.user_entries
        e["full_name"].set_text(answers.get("full_name", ""))
        e["user_name"].set_text(answers.get("user", ""))
        e["password"].set_text(self.password)
        e["confirm"].set_text(answers.get("confirm", self.password))
        if "hostname" in answers:
            e["hostname"].set_text(answers["hostname"])
        self.win.ssh_view.get_buffer().set_text(answers.get("ssh_key", ""))
        self.click("next")

    def page_network(self):
        win = self.win
        answers = self.answers
        mode = answers.get("network", "dhcp")
        if mode == "offline":
            win.mode_offline.set_active(True)
        else:
            select_name(win.net_view, answers.get("net_if", ""))
            (win.mode_static if mode == "static" else win.mode_dhcp).set_active(True)
            for key in ("ipv4_addr", "ipv4_mask", "ipv4_gw"):
                if key in answers:
                    win.net_entries[key].set_text(answers[key])
        self.click("next")

    def page_summary(self):
        win = self.win
        self.click("install")
        took = False
        while win.running:
            Gtk.main_iteration_do(True)
            if not took and win.inst_bar.get_fraction() >= 0.4:
                self.shot()
                took = True
        self.pump()

    def page_install(self):
        self.shot()
        raise SystemExit("smoke: the installation failed")

    def page_finish(self):
        self.shot()
        return "done"

    def step(self):
        handler = self.pages.get(self.win.page)
        return handler() if handler is not None else None

    def stuck(self, before):
        """The page did not change and it shows an error."""
        text = self.win.error_label.get_text()
        return bool(text) and (self.win.page, text) == before

    def run(self):
        import json
        win = self.win
        win.start()
        for _ in range(40):
            before = (win.page, win.error_label.get_text())
            if self.step() == "done":
                break
            if self.stuck(before):
                self.shot()
                raise SystemExit(f"smoke: {win.page}: {win.error_label.get_text()}")
        print("smoke: pages " + " ".join(self.seen))
        if self.shots:
            W.write_new_file(os.path.join(self.shots, "layout.json"),
                             json.dumps(self.layouts, indent=1).encode("utf-8"))
        return W.EXIT_OK if win.page == "finish" else W.EXIT_FAILED


def smoke(win, answers, password, shots):
    """Walk every page with the given answers, the way a person would."""
    return Smoke(win, answers, password, shots).run()


def main():
    windowed = "--windowed" in ARGS or "--smoke" in ARGS
    wiz = W.Wizard(ROOT)
    size = None
    if "--size" in ARGS:
        try:
            w, h = ARGS[ARGS.index("--size") + 1].lower().split("x")
            size = (int(w), int(h))
        except (IndexError, ValueError):
            sys.stderr.write("installer-gui: --size takes WIDTHxHEIGHT\n")
            return 2
    if "--text-scale" in ARGS and "--smoke" in ARGS:
        # For the smoke run: larger text, the way a screen with more dots
        # per inch or a larger font shows it.
        try:
            factor = float(ARGS[ARGS.index("--text-scale") + 1])
        except (IndexError, ValueError):
            sys.stderr.write("installer-gui: --text-scale takes a number\n")
            return 2
        Gtk.Settings.get_default().set_property("gtk-xft-dpi", int(96 * 1024 * factor))
    win = InstallerWindow(wiz, windowed=windowed, offscreen="--screenshots" in ARGS, size=size)
    win.show_all()
    if win.offscreen is not None:
        win.offscreen.show_all()
    try:
        if "--smoke" in ARGS:
            import json
            path = ARGS[ARGS.index("--smoke") + 1]
            with open(path, encoding="utf-8") as stream:
                answers = json.load(stream)
            password = sys.stdin.readline().rstrip("\n")
            shots = ARGS[ARGS.index("--screenshots") + 1] if "--screenshots" in ARGS else ""
            return smoke(win, answers, password, shots)
        def on_signal():
            # An interrupted run ends like the text front end: the
            # installation is stopped, the state is removed, the log kept.
            win.result = W.EXIT_FAILED
            win.quit()
            return False

        import signal
        import warnings
        with warnings.catch_warnings():
            # Newer PyGObject moved this to GLibUnix; the BSDs ship older ones.
            warnings.simplefilter("ignore", DeprecationWarning)
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                GLib.unix_signal_add(GLib.PRIORITY_HIGH, number, on_signal)
        GLib.idle_add(lambda: (win.start(), False)[1])
        Gtk.main()
        return win.result
    finally:
        wiz.close()


if __name__ == "__main__":
    sys.exit(main())

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
    if "--smoke" in ARGS or "--screenshots" in ARGS or "--render" in ARGS or "--keyboard-walk" in ARGS:
        sys.stderr.write("installer-gui: --smoke, --screenshots and --render are refused for root\n")
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
import i18n  # noqa: E402


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

from gui_lists import not_a_list, scrolled  # noqa: E402

CSS = b"""
.flag-button { padding: 2px 4px; min-width: 30px; }
.flag-badge { font-size: 10px; font-weight: bold; color: #333333; background-color: #e3e7ee;
              border-radius: 3px; padding: 1px 4px; }
.flag-button:checked { background-image: none; background-color: #cfe0ff; border-color: #4c8bf5; }
button:focus, radiobutton:focus, checkbutton:focus, entry:focus, treeview:focus,
spinbutton:focus, combobox:focus, scale:focus, flowboxchild:focus {
    outline-color: #4c8bf5; outline-style: solid; outline-width: 2px; outline-offset: 1px; }
/* The outline is only drawn while the toolkit thinks the keyboard is in
   use, which some systems never report: a button with the focus also gets
   a ring of its own, always. */
button:focus { box-shadow: inset 0 0 0 2px #4c8bf5, 0 0 0 1px #4c8bf5; }
button.suggested-action:focus, button.destructive-action:focus {
    box-shadow: inset 0 0 0 2px #ffffff, 0 0 0 2px #4c8bf5; }
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
.tagline { font-size: 12px; }
.error-text { color: #c01c28; }
.warning-text { color: #a05a00; font-weight: bold; }
.action-bar { padding: 12px 18px; border-top: 1px solid alpha(#000000, 0.12); }
.action-bar button { min-width: 120px; min-height: 36px; }
.field-label { font-weight: bold; }
"""

PAGE_TITLES = dict(W.PAGES)


# The message of a page whose fields show their own problems.
FIELDS_NEED_ATTENTION = "Some fields need attention."


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


def svg_pixbuf(data, width, height, fill=False):
    """A pixbuf of SVG bytes at a size (the whole area when fill), or None."""
    if not data:
        return None
    try:
        loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
        loader.write(data)
        loader.close()
        pix = loader.get_pixbuf()
    except GLib.Error:
        return None
    if fill:
        scale = max(width / pix.get_width(), height / pix.get_height())
        scaled = pix.scale_simple(int(pix.get_width() * scale) + 1, int(pix.get_height() * scale) + 1,
                                  GdkPixbuf.InterpType.BILINEAR)
        return scaled.new_subpixbuf(0, 0, min(width, scaled.get_width()), min(height, scaled.get_height()))
    scale = min(width / pix.get_width(), height / pix.get_height())
    return pix.scale_simple(max(int(pix.get_width() * scale), 1), max(int(pix.get_height() * scale), 1),
                            GdkPixbuf.InterpType.BILINEAR)


def wrap_toggle_labels(widget):
    if isinstance(widget, Gtk.CheckButton) and isinstance(widget.get_child(), Gtk.Label):
        child = widget.get_child()
        child.set_line_wrap(True)
        child.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        child.set_max_width_chars(60)
        child.set_xalign(0.0)
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            wrap_toggle_labels(child)


def mnemonic_label(text, used):
    """The label with an underline before its first letter that no other
    button of the cluster uses, and that letter."""
    for i, ch in enumerate(text):
        if ch.isalpha() and ch.lower() not in used:
            return text[:i] + "_" + text[i:].replace("_", "__"), ch.lower()
    return text.replace("_", "__"), ""


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
        self.lang = "en"
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
        import gui_disk
        import gui_software
        import branding
        # The look of the product: its artwork template, next to the
        # installer (install-into-stage.sh --artwork), or INSTALLER_ARTWORK.
        art = os.environ.get("INSTALLER_ARTWORK") or os.path.join(ROOT, "artwork")
        # The identity of the image (lib/identity.py): the line in the lower
        # left, and the variant of the artwork it was built with.
        import identity
        import platform
        self.identity = identity.load(os.environ.get("INSTALLER_IDENTITY") or
                                      identity.path_for(self.wiz.slug))
        if offscreen:
            # A picture (--render, --smoke) shows the system it is drawn
            # for: the BASE of a sample identity file never names another.
            self.identity = identity.for_os(self.identity, self.wiz.os_name)
        uname = os.uname()
        self.identity_text = identity.line(
            self.identity, self.wiz.product, platform.machine(),
            identity.detected_base((uname.sysname, uname.release), self.wiz.os_name))
        try:
            self.brand = branding.load(art if os.path.isfile(os.path.join(art, "palette.env")) else "",
                                       self.identity.get("VARIANT", ""))
        except (branding.BrandingError, OSError) as error:
            sys.stderr.write(f"installer-gui: the artwork cannot be used: {error}\n")
            self.brand = branding.load("")
        for css in (CSS, gui_disk.CSS, gui_software.CSS, self.brand.css().encode("utf-8")):
            provider = Gtk.CssProvider()
            provider.load_from_data(css)
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.disk_page = gui_disk.DiskPage(self)
        self.software_page = gui_software.SoftwarePage(self)
        import gui_network
        self.network_page = gui_network.NetworkPage(self)
        self.connect("delete-event", self.on_delete)
        self.connect("key-press-event", self.on_key)
        self.connect("key-release-event", self.on_key_release)
        self.connect("focus-out-event", lambda *_a: setattr(self, "alt_down", False))

        outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        # The smoke run draws the pages in an offscreen window, so that a
        # picture of every page can be taken on any display backend.
        self.offscreen = None
        if offscreen:
            self.offscreen = Gtk.OffscreenWindow()
            width, height = size or (1024, 768)
            self.offscreen.set_size_request(width, height)
            self.offscreen.add(outer)
            self.offscreen.connect("key-press-event", self.on_key)
            self.offscreen.connect("key-release-event", self.on_key_release)
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
        # Shown while a slow probe runs (the disks of a system can take
        # minutes to read): the window stays alive, the buttons wait.
        self.busy_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.busy_spinner = Gtk.Spinner()
        self.busy_label = label("Reading the hardware\u2026", "muted", wrap=False)
        self.busy_box.pack_start(self.busy_spinner, False, False, 0)
        self.busy_box.pack_start(self.busy_label, False, False, 0)
        self.busy_box.set_no_show_all(True)
        bar.pack_start(self.busy_box, False, False, 0)
        self.busy = False
        self.busy_stats = {"waits": 0, "iterations": 0, "longest": 0.0}
        self.wiz.backend.runner = self.background
        main.pack_end(bar, False, False, 0)

        self.builders = {
            "preflight": self.page_preflight, "welcome": self.page_welcome,
            "keyboard": self.page_keyboard, "timezone": self.page_timezone,
            "type": self.page_type, "disk": self.page_disk, "users": self.page_users,
            "network": self.page_network, "software": self.page_software,
            "summary": self.page_summary,
            "install": self.page_install, "finish": self.page_finish,
            "hardware": self.page_hardware,
        }
        for name, build in self.builders.items():
            self.stack.add_named(build(), name)
        # The label of every check and radio button wraps: no long label
        # makes a page wider than the screen.
        wrap_toggle_labels(self.stack)
        self.stack.set_hhomogeneous(False)
        # The page scrolls by its own height, not the height of the tallest.
        self.stack.set_vhomogeneous(False)
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
        logo = svg_pixbuf(self.brand.svg("logo"), 72, 72)
        if logo is None and self.wiz.logo:
            try:
                logo = GdkPixbuf.Pixbuf.new_from_file_at_scale(self.wiz.logo, 160, 96, True)
            except GLib.Error:
                logo = None
        if logo is not None:
            image = Gtk.Image.new_from_pixbuf(logo)
            image.set_halign(Gtk.Align.START)
            head.pack_start(image, False, False, 0)
        head.pack_start(label(self.wiz.product, "product"), False, False, 0)
        if self.brand.palette.get("TAGLINE"):
            head.pack_start(label(self.brand.palette["TAGLINE"], "tagline"), False, False, 0)
        side.pack_start(head, False, False, 0)
        self.step_labels = {}
        for ident, title in W.PAGES:
            widget = label(title, "step", wrap=False)
            self.step_labels[ident] = widget
            side.pack_start(widget, False, False, 0)
        # Which product, version, variant and architecture this is, small
        # and understated in the lower left: every picture says it.
        self.identity_label = label(self.identity_text, "identity")
        self.identity_label.set_margin_start(18)
        self.identity_label.set_margin_bottom(12)
        self.identity_label.set_margin_end(12)
        self.identity_label.set_max_width_chars(34)
        side.pack_end(self.identity_label, False, False, 0)
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
        used = set()
        acts = self.wiz.actions(self.page, failed=self.wiz.install_failed and not self.running,
                                running=self.running, failure=self.failure)
        primary = None
        for act in acts:
            # Every button has a mnemonic: Alt and its underlined letter.
            key = "action.install-product" if (self.page, act.ident) == ("welcome", "next") \
                else f"action.{act.ident}"
            text = i18n.t(key, self.lang, product=self.wiz.product) \
                if key in i18n.STRINGS["en"] else act.label
            label, letter = mnemonic_label(text, used)
            used.add(letter)
            button = Gtk.Button.new_with_mnemonic(label)
            button.mnemonic_letter = letter
            button.is_primary = bool(act.primary)
            button.is_destructive = bool(act.destructive)
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
        install = getattr(self, "buttons", {}).get("install")
        if install is not None and self.page == "summary":
            install.set_sensitive(self.wiz.install_allowed())
        button = self.buttons.get("next")
        if button is None:
            return
        if self.page in ("keyboard", "timezone"):
            view = self.kb_view if self.page == "keyboard" else self.tz_view
            button.set_sensitive(bool(selected_name(view)))
        else:
            button.set_sensitive(True)

    def background(self, func, *args):
        """Run func (a backend command) in a thread of its own; the main loop
        keeps running (the window redraws, the spinner turns), the buttons
        and the keys wait until it is done.  The result, or its exception."""
        import threading
        import time
        if self.busy or threading.current_thread() is not threading.main_thread():
            return func(*args)
        result = {}

        def work():
            try:
                result["value"] = func(*args)
            except BaseException as error:  # NOSONAR python:S5754 - re-raised in the main thread below
                result["error"] = error
        thread = threading.Thread(target=work, daemon=True)
        started = time.monotonic()
        self.busy = True
        self.actions_box.set_sensitive(False)
        self.busy_box.show()
        self.busy_spinner.show()
        self.busy_label.show()
        self.busy_spinner.start()
        thread.start()
        try:
            while thread.is_alive():
                Gtk.main_iteration_do(False)
                self.busy_stats["iterations"] += 1
                thread.join(0.01)
        finally:
            self.busy = False
            self.busy_spinner.stop()
            self.busy_box.hide()
            self.actions_box.set_sensitive(True)
            self.busy_stats["waits"] += 1
            self.busy_stats["longest"] = max(self.busy_stats["longest"], time.monotonic() - started)
        if "error" in result:
            raise result["error"]
        return result.get("value")

    def show_page(self, page):
        if page != getattr(self, "page", None):
            self.wiz.forget_disks()
        self.page = page
        self.error_label.set_text("")
        if page == "preflight":
            self.title_label.set_text("Unfortunately")
        else:
            self.title_label.set_text(i18n.t(f"page.{page}", self.lang))
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
        if self.busy:
            return
        handler = getattr(self, "act_" + ident.replace("-", "_"))
        handler()

    def act_back(self):
        if self.page == "install":
            self.wiz.install_failed = False
            self.show_page("summary")
            return
        self.show_page(self.wiz.prev_page(self.page))

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
        self.show_page(self.wiz.next_page(self.page))

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

    ALT_KEYS = ("Alt_L", "Alt_R", "Meta_L", "Meta_R")

    def on_key_release(self, _widget, event):
        if Gdk.keyval_name(event.keyval) in self.ALT_KEYS:
            self.alt_down = False
        return False

    def alt_held(self, event):
        """Alt is down: the modifier of the event (Mod1, or Meta where the X
        server maps Alt there), or an Alt key pressed and not yet released
        (a server that does not set the modifier on the next key)."""
        mask = Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.META_MASK
        return bool(event.state & mask) or getattr(self, "alt_down", False)

    def event_letter(self, event):
        """The letter of a key, also when Alt turned its keysym into another
        one: the key read again without modifiers."""
        letter = chr(Gdk.keyval_to_unicode(Gdk.keyval_to_lower(event.keyval)) or 0)
        if letter.isalpha():
            return letter
        keymap = Gdk.Keymap.get_for_display(Gdk.Display.get_default())
        ok, keyval, *_rest = keymap.translate_keyboard_state(event.hardware_keycode, 0, event.group)
        if ok:
            letter = chr(Gdk.keyval_to_unicode(Gdk.keyval_to_lower(keyval)) or 0)
        return letter if letter.isalpha() else ""

    def on_key(self, _widget, event):
        if self.busy:
            return True
        if Gdk.keyval_name(event.keyval) in self.ALT_KEYS:
            self.alt_down = True
            return False
        if event.keyval == Gdk.KEY_Escape:
            self.request_close()
            return True
        if self.return_on_list(event):
            return True
        return self.alt_mnemonic(event)

    def return_on_list(self, event):
        """Return on a row of a list (the layouts, the zones, the disks) goes
        on, like the primary button: the row is the choice.  The page
        checks itself the way the button does.  Whether it went on."""
        if event.keyval not in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter) or \
                event.state & (Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.CONTROL_MASK):
            return False
        focus = self.get_focus() if self.offscreen is None else self.offscreen.get_focus()
        if not isinstance(focus, Gtk.TreeView):
            return False
        primary = self.primary_button()
        # Never the destructive Install: that is chosen by itself.
        if primary is None or not primary.get_sensitive() or \
                getattr(primary, "is_destructive", False):
            return False
        primary.clicked()
        return True

    def alt_mnemonic(self, event):
        """Alt and the underlined letter of a button of the action cluster
        presses it, on every display (the toolkit's own mnemonics need a
        display that reports the Alt key the usual way).  Whether it did."""
        if not self.alt_held(event):
            return False
        letter = self.event_letter(event)
        for button in getattr(self, "buttons", {}).values():
            if getattr(button, "mnemonic_letter", "") == letter and button.get_sensitive():
                button.clicked()
                return True
        return False

    def primary_button(self):
        """The primary button of the action cluster: the rightmost one."""
        for ident, button in getattr(self, "buttons", {}).items():
            if getattr(button, "is_primary", False):
                return button
        return None

    def focus_first(self, widget):
        """The first control of a page has the focus, so the page works from
        the keyboard alone."""
        if widget is not None and widget.get_can_focus():
            widget.grab_focus()

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
        # The focus is shown from the start: the installer is used from the
        # keyboard as often as with a pointer.
        self.set_focus_visible(True)
        if self.offscreen is not None:
            self.offscreen.set_focus_visible(True)
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
        # The text and the languages side by side, or the languages under
        # the text when the screen is narrow.
        outer = not_a_list(Gtk.FlowBox(), "the two halves of the Welcome page")
        outer.set_selection_mode(Gtk.SelectionMode.NONE)
        outer.set_min_children_per_line(1)
        outer.set_max_children_per_line(2)
        outer.set_column_spacing(28)
        outer.set_row_spacing(16)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER)
        self.welcome_ready = label("", "lead-big")
        self.welcome_text = label("", "lead")
        self.welcome_live = label("")
        self.hardware_button = Gtk.Button(label="Hardware and drivers")
        self.hardware_button.set_halign(Gtk.Align.START)
        self.hardware_button.connect("clicked", lambda *_a: self.open_hardware())
        for widget in (self.welcome_ready, self.welcome_text, self.welcome_live):
            widget.set_max_width_chars(40)
            box.pack_start(widget, False, False, 0)
        box.pack_start(self.hardware_button, False, False, 0)
        outer.add(box)
        # The languages: one row each, the flags of its variants on the
        # right; the choice sets the language of the installed system and
        # of the installer when it has strings in it.
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.welcome_language = label("", "field-label")
        side.pack_start(self.welcome_language, False, False, 0)
        self.lang_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        scroller = Gtk.ScrolledWindow()
        # The list scrolls both ways: the page never grows wider than the
        # screen, whatever the size of the text.
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroller.set_min_content_height(320)
        scroller.set_min_content_width(280)
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.add(self.lang_list)
        side.pack_start(scroller, True, True, 0)
        outer.add(side)
        self.flag_buttons = {}
        return outer

    def enter_welcome(self):
        if not self.flag_buttons:
            self.fill_languages()
        self.set_language(i18n.language_of(self.wiz.answers.locale))

    def flag_widget(self, country):
        """The flag of a region: an image shipped with the installer
        (gui/flags), never a character a colour emoji font may not draw;
        without an image the two letters of the region in a badge."""
        scale = self.get_scale_factor() if hasattr(self, "get_scale_factor") else 1
        path = i18n.flag_file(country, os.path.join(ROOT, "gui", "flags"), scale)
        if path is not None:
            try:
                pix = GdkPixbuf.Pixbuf.new_from_file(path)
                if scale >= 2 and pix.get_width() > 24 and Gdk is not None:
                    surface = Gdk.cairo_surface_create_from_pixbuf(pix, scale, None)
                    return Gtk.Image.new_from_surface(surface)
                return Gtk.Image.new_from_pixbuf(pix)
            except GLib.Error:
                pass
        badge = Gtk.Label(label=country.upper()[:2])
        badge.get_style_context().add_class("flag-badge")
        return badge

    def fill_languages(self):
        group = None
        for lang, own, english, variants in i18n.languages_for(self.wiz.system_locales()):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.set_border_width(4)
            names = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            names.pack_start(label(own, "field-label", wrap=False), False, False, 0)
            if own != english:
                names.pack_start(label(english, "muted", wrap=False), False, False, 0)
            row.pack_start(names, True, True, 0)
            for locale, country, region in variants:
                button = Gtk.RadioButton.new_from_widget(group)
                group = group or button
                button.set_mode(False)
                button.add(self.flag_widget(country))
                button.get_style_context().add_class("flag-button")
                button.flag_country = country
                button.set_tooltip_text(f"{own} ({region}) — {locale}")
                button.connect("toggled", self.on_locale, locale)
                self.flag_buttons[locale] = button
                row.pack_start(button, False, False, 0)
            self.lang_list.pack_start(row, False, False, 0)
        self.lang_list.show_all()
        current = self.flag_buttons.get(self.wiz.answers.locale)
        if current is not None:
            current.set_active(True)

    def on_locale(self, button, locale):
        if not button.get_active():
            return
        self.wiz.answers.locale = locale
        self.set_language(i18n.language_of(locale))
        if hasattr(self, "locale_combo"):
            self.locale_combo.set_active_id(locale)

    def set_language(self, lang):
        """The installer speaks the language when it has strings in it."""
        self.lang = lang if i18n.translated(lang) else "en"
        product = self.wiz.product
        for ident, widget in self.step_labels.items():
            widget.set_text(i18n.t(f"page.{ident}", self.lang))
        if self.page in W.PAGE_IDS:
            self.title_label.set_text(i18n.t(f"page.{self.page}", self.lang))
        self.welcome_ready.set_text(i18n.t("welcome.ready", self.lang, product=product))
        self.welcome_text.set_text(i18n.t("welcome.text", self.lang, product=product))
        self.welcome_live.set_text(i18n.t("welcome.live", self.lang, product=product))
        self.welcome_language.set_text(i18n.t("welcome.language", self.lang))
        self.hardware_button.set_label(i18n.t("hardware.button", self.lang))
        if hasattr(self, "inst_details"):
            self.inst_details.set_label(i18n.t("installing.details", self.lang))
        if hasattr(self, "buttons"):
            self.set_actions()

    def page_keyboard(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        row.pack_start(label("Language of the installed system", "field-label", wrap=False),
                       False, False, 0)
        self.locale_combo = Gtk.ComboBoxText()
        self.locale_combo.connect("changed", self.on_locale_combo)
        row.pack_start(self.locale_combo, False, False, 0)
        box.pack_start(row, False, False, 0)
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

    def fill_locales(self):
        self.locale_combo.remove_all()
        for lang, own, english, variants in i18n.languages_for(self.wiz.system_locales()):
            for locale, country, region in variants:
                # Text only: a flag character needs a colour emoji font.
                self.locale_combo.append(locale, f"{own} ({region})")
        self.locale_combo.set_active_id(self.wiz.answers.locale)

    def enter_keyboard(self):
        if not len(self.kb_store):
            for item in self.wiz.keymaps():
                self.kb_store.append([item.name, item.descr])
        self.fill_locales()
        select_name(self.kb_view, self.wiz.answers.keymap)
        suggest = i18n.keymap_for(self.wiz.answers.locale, [row[0] for row in self.kb_store])
        if suggest and self.wiz.answers.keymap in ("", "us") and suggest != "us":
            select_name(self.kb_view, suggest)
        self.focus_first(self.kb_view)

    def on_locale_combo(self, combo):
        locale = combo.get_active_id()
        if not locale or locale == self.wiz.answers.locale and getattr(self, "_kb_suggested", False):
            return
        self.wiz.answers.locale = locale
        # The layout follows the language until the user picks one.
        suggest = i18n.keymap_for(locale, [row[0] for row in self.kb_store])
        if suggest and not getattr(self, "_kb_touched", False):
            select_name(self.kb_view, suggest)
        self._kb_suggested = True

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
        self.tz_clock = label("", "lead")
        box.pack_start(self.tz_clock, False, False, 0)
        self.tz_view.get_selection().connect("changed", self.update_clock)
        box.pack_start(label("The clock of this computer keeps", "field-label"), False, False, 0)
        self.clock_utc = Gtk.RadioButton.new_with_label(
            None, "UTC (recommended; the system shows the time of the zone above)")
        self.clock_local = Gtk.RadioButton.new_with_label_from_widget(
            self.clock_utc, "the local time (needed when Windows shares this computer)")
        box.pack_start(self.clock_utc, False, False, 0)
        box.pack_start(self.clock_local, False, False, 0)
        return box

    def tz_visible(self, model, it, _data):
        text = self.tz_search.get_text().strip().lower().replace(" ", "_")
        return not text or text in (model[it][0] + " " + model[it][1]).lower().replace(" ", "_")

    def enter_timezone(self):
        if not len(self.tz_store):
            for item in self.wiz.zones():
                self.tz_store.append([item.name, item.descr])
        select_name(self.tz_view, self.wiz.answers.timezone)
        (self.clock_local if self.wiz.answers.clock == "local" else self.clock_utc).set_active(True)
        # Windows on a disk of this computer keeps the clock in local time.
        detail = self.wiz.disk_detail if self.wiz.disk_detail.get("disks") else self.wiz.disk_report()[0]
        if self.wiz.answers.clock == "utc" and any(
                o.get("name") == "Windows" for d in detail.get("disks", []) for o in d.get("os", [])):
            self.clock_local.set_active(True)
        self.update_clock()
        self.focus_first(self.tz_view)

    def collect_timezone(self):
        name = selected_name(self.tz_view)
        if not name:
            return "Choose a time zone."
        self.wiz.answers.timezone = name
        self.wiz.answers.clock = "local" if self.clock_local.get_active() else "utc"
        return None

    def update_clock(self, *_args):
        """The time now in the zone that is picked."""
        import datetime
        name = selected_name(self.tz_view) or "UTC"
        try:
            import zoneinfo
            now = datetime.datetime.now(zoneinfo.ZoneInfo(name))
            self.tz_clock.set_text(f"Now in {name}: {now:%H:%M}, {now:%A %d %B %Y}")
        except Exception:  # noqa: BLE001 - no zone data: no clock
            self.tz_clock.set_text("")
        return True

    def page_type(self):
        return self.disk_page.build_type()

    def enter_type(self):
        self.disk_page.load_type()
        dp = self.disk_page
        self.focus_first(dp.mode_buttons[dp.mode] if not dp.notice.get_visible() else None)

    def collect_type(self):
        return self.disk_page.collect_type()

    def page_software(self):
        return self.software_page.build()

    def enter_software(self):
        self.software_page.load()
        sp = self.software_page
        first = next(iter(sp.checks.values()), None)
        self.focus_first(first)

    def collect_software(self):
        return self.software_page.collect()

    def page_disk(self):
        return self.disk_page.build()

    def enter_disk(self):
        self.disk_page.load()
        self.disk_page.apply_mode()
        self.title_label.set_text(f"Disk — {self.disk_page.mode_title()}")
        dp = self.disk_page
        if dp.asks_usage() and dp.usage is None:
            self.focus_first(dp.usage_buttons["together"])
        elif dp.mode in ("erase", "manual"):
            self.focus_first(dp.view)

    def collect_disk(self):
        return self.disk_page.collect()

    def message(self, primary, secondary):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True,
                                   message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK, text=primary)
        dialog.format_secondary_text(secondary)
        dialog.run()
        dialog.destroy()

    def ask_text(self, primary, secondary):
        """A question answered by typing: the text, or None for Cancel."""
        dialog = Gtk.MessageDialog(transient_for=self, modal=True,
                                   message_type=Gtk.MessageType.WARNING,
                                   buttons=Gtk.ButtonsType.NONE, text=primary)
        dialog.format_secondary_text(secondary)
        entry = Gtk.Entry()
        dialog.get_message_area().pack_start(entry, False, False, 0)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Confirm", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        dialog.show_all()
        answer = dialog.run()
        text = entry.get_text()
        dialog.destroy()
        return text if answer == Gtk.ResponseType.OK else None

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
        row += 1
        self.autologin = Gtk.CheckButton(
            label="Log in automatically (no password at the start of the computer)")
        grid.attach(self.autologin, 1, row, 1, 1)
        row += 1
        # The strength of the password, under its field.
        self.pw_strength = Gtk.LevelBar(min_value=0, max_value=4)
        self.pw_strength.set_size_request(200, 8)
        self.pw_strength_text = label("", "muted")
        strength = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        strength.pack_start(self.pw_strength, False, False, 0)
        strength.pack_start(self.pw_strength_text, False, False, 0)
        grid.insert_row(6)
        grid.attach(strength, 1, 6, 1, 1)
        self.user_entries["password"].connect("changed", self.on_password_changed)
        # The root account.
        row += 2
        grid.attach(label("The root account", "field-label"), 0, row, 1, 1)
        self.root_locked = Gtk.RadioButton.new_with_label(
            None, "Locked: administer the system with sudo or doas (recommended)")
        self.root_own = Gtk.RadioButton.new_with_label_from_widget(
            self.root_locked, "Give root a password of its own")
        grid.attach(self.root_locked, 1, row, 1, 1)
        grid.attach(self.root_own, 1, row + 1, 1, 1)
        roots = Gtk.Grid(column_spacing=8, row_spacing=4)
        self.root_pw = Gtk.Entry(visibility=False, placeholder_text="Root password")
        self.root_pw2 = Gtk.Entry(visibility=False, placeholder_text="Confirm the root password")
        for i, (entry, text) in enumerate(((self.root_pw, "R_oot password"),
                                           (self.root_pw2, "Confirm the root pass_word"))):
            entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            entry.set_hexpand(True)
            roots.attach(field_label(text, entry), 0, i, 1, 1)
            roots.attach(entry, 1, i, 1, 1)
        grid.attach(roots, 1, row + 2, 1, 1)
        self.root_error = label("", "error-text")
        grid.attach(self.root_error, 1, row + 3, 1, 1)

        def gate(*_a):
            # The root password is typeable only for a root with a password.
            for entry in (self.root_pw, self.root_pw2):
                entry.set_sensitive(self.root_own.get_active())
        self.root_own.connect("toggled", gate)
        gate()
        return grid

    def on_password_changed(self, entry):
        import diskplan
        score, word = diskplan.passphrase_strength(entry.get_text())
        self.pw_strength.set_value(score)
        self.pw_strength_text.set_text(f"strength: {word}" if entry.get_text() else "")

    def enter_users(self):
        a = self.wiz.answers
        self.user_entries["full_name"].set_text(a.full_name)
        self.user_entries["user_name"].set_text(a.user_name)
        self.user_entries["hostname"].set_text(a.hostname)
        self.ssh_view.get_buffer().set_text(a.ssh_key)
        self.priv_check.set_active(a.privilege_passwordless)
        self.autologin.set_active(a.autologin)
        (self.root_own if a.root_mode == "password" else self.root_locked).set_active(True)
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
            return FIELDS_NEED_ATTENTION
        a = self.wiz.answers
        a.user_name, a.full_name, a.hostname = get["user_name"], get["full_name"], get["hostname"]
        a.ssh_key = ssh_key
        a.privilege_passwordless = self.priv_check.get_active()
        a.autologin = self.autologin.get_active()
        self.root_error.set_text("")
        if self.root_own.get_active():
            if not self.root_pw.get_text():
                self.root_error.set_text("Type a password for root.")
                return FIELDS_NEED_ATTENTION
            if self.root_pw.get_text() != self.root_pw2.get_text():
                self.root_error.set_text("The root passwords do not match.")
                return FIELDS_NEED_ATTENTION
            try:
                self.wiz.set_root_password(self.root_pw.get_text())
            except (W.passhash.HashError, OSError) as error:
                return f"The root password cannot be stored: {error}"
        else:
            a.root_mode = "locked"
        try:
            # nosemgrep: python.django.security.audit.unvalidated-password.unvalidated-password -- not Django; checked by Wizard.check_users above (not empty, matches the confirmation) and refused again by passhash.make_hash before it is hashed
            self.wiz.set_password(get["password"])
        except (W.passhash.HashError, OSError) as error:
            return f"The password cannot be stored: {error}"
        return None

    def page_network(self):
        return self.network_page.build()

    def enter_network(self):
        self.network_page.load()
        first = self.network_page.tabs[0].v4[0] if self.network_page.tabs else self.network_page.offline
        self.focus_first(first)

    def collect_network(self):
        return self.network_page.collect()

    def page_summary(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.pack_start(label("The installation will use:"), False, False, 0)
        # The answers in groups, two groups side by side where they fit,
        # so the list of the disks starts on the first screen.
        self.sum_grid = Gtk.Grid(column_spacing=28, row_spacing=10)
        self.sum_grid.set_column_homogeneous(True)
        box.pack_start(self.sum_grid, False, False, 0)
        self.sum_warning = label("", "warning-text")
        box.pack_start(self.sum_warning, False, False, 0)
        # What happens to every disk; the destructive actions in red.
        self.sum_disks_title = label("What happens to the disks", "field-label")
        box.pack_start(self.sum_disks_title, False, False, 0)
        self.sum_disks = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        # One line a disk: many disks scroll, the confirmation stays.
        box.pack_start(scrolled(self.sum_disks, 2, 6, name="summary-disks"), False, False, 0)
        # Erasing a disk that holds another system: the word, typed.
        self.sum_confirm_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.sum_confirm_text = label("", "error-text")
        self.sum_confirm_box.pack_start(self.sum_confirm_text, False, False, 0)
        self.sum_confirm = Gtk.Entry()
        self.sum_confirm.set_placeholder_text(f"type {W.Wizard.CONFIRM_WORD}")
        self.sum_confirm.set_max_width_chars(20)
        self.sum_confirm.set_halign(Gtk.Align.START)
        self.sum_confirm.connect("changed", lambda e: (self.wiz.confirm_erase(e.get_text()),
                                                       self.refresh_sensitivity()))
        self.sum_confirm_box.pack_start(self.sum_confirm, False, False, 0)
        box.pack_start(self.sum_confirm_box, False, False, 0)
        box.pack_start(label(f"Choose Install to install {self.wiz.product} with these "
                             "settings."), False, False, 0)
        return box

    def enter_summary(self):
        self.fill_summary_groups()
        self.sum_disks_title.set_text(self.wiz.disk_row()[1] or "What happens to the disks")
        problems = self.wiz.install_problems()
        if problems:
            text = "; ".join(problems)
            self.sum_warning.set_text(f"Install is not possible yet: {text}.")
        else:
            self.sum_warning.set_text(self.wiz.erase_warning())
        self.fill_summary_disks()
        foreign = self.wiz.foreign_to_confirm()
        self.sum_confirm_box.set_visible(bool(foreign))
        self.sum_confirm.set_text("")
        self.wiz.confirm_erase("")
        if foreign:
            self.sum_confirm_text.set_text(
                f"{', '.join(foreign)} holds another system, and everything on it is deleted. "
                f"Type {W.Wizard.CONFIRM_WORD} to confirm.")
            self.sum_confirm.grab_focus()

    def fill_summary_groups(self):
        """The answers in groups, two groups side by side where they fit."""
        for child in self.sum_grid.get_children():
            self.sum_grid.remove(child)
        columns = 2 if self.page_scroller.get_allocated_width() >= 640 or \
            self.page_scroller.get_allocated_width() <= 1 else 1
        for index, (title, rows) in enumerate(self.wiz.summary_sections()):
            group = Gtk.Grid(column_spacing=12, row_spacing=3)
            group.attach(label(title, "section-title"), 0, 0, 2, 1)
            for row, (name, value) in enumerate(rows, start=1):
                group.attach(label(name, "muted", wrap=False), 0, row, 1, 1)
                text = label(value)
                text.set_max_width_chars(28)
                group.attach(text, 1, row, 1, 1)
            self.sum_grid.attach(group, index % columns, index // columns, 1, 1)
        self.sum_grid.show_all()

    def fill_summary_disks(self):
        """What happens to every disk, one line a disk."""
        for child in self.sum_disks.get_children():
            self.sum_disks.remove(child)
        for disk, text, destructive in self.wiz.disk_actions():
            line = label((f"{disk}: " if disk else "") + text,
                         "error-text" if destructive else None)
            self.sum_disks.pack_start(line, False, False, 0)
        self.sum_disks.show_all()

    # ---------------------------------------------------- hardware
    def page_hardware(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.hw_intro = label("", "lead")
        box.pack_start(self.hw_intro, False, False, 0)
        self.hw_store = Gtk.ListStore(str, str, str, str, str)
        view = Gtk.TreeView(model=self.hw_store)
        for index, title in enumerate(("Part", "Device", "Driver", "Firmware", "Status")):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(title, renderer, markup=index)
            column.set_expand(index == 1)
            view.append_column(column)
        self.hw_view = view
        box.pack_start(scrolled(view, 4, 12, name="hardware"), False, False, 0)
        box.pack_start(label("A part without a driver or without its firmware may not work in "
                             "the installed system; the installer still installs it.", "muted"),
                       False, False, 0)
        self.hw_missing = label("", "muted")
        box.pack_start(self.hw_missing, False, False, 0)
        return box

    def open_hardware(self):
        self.return_page = self.page
        self.show_page("hardware")

    def enter_hardware(self):
        self.title_label.set_text(i18n.t("hardware.title", self.lang))
        self.hw_intro.set_text(i18n.t("hardware.intro", self.lang))
        self.hw_store.clear()
        esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")  # noqa: E731
        for d in self.wiz.hardware():
            firmware = esc(d["firmware"])
            if d["firmware"] == "missing":
                firmware = f'<span foreground="#c01c28">{firmware}</span>'
            status = esc(d["status"])
            status = (f'<span foreground="#26803a">{status}</span>' if d["status"] == "working"
                      else f'<span foreground="#a05a00">{status}</span>')
            self.hw_store.append([esc(d["class"]), esc(d["name"]), esc(d["driver"] or "none"),
                                  firmware, status])
        missing = getattr(self.wiz, "hardware_unavailable", [])
        self.hw_missing.set_text("Not available on this system: " + "; ".join(missing) + "."
                                 if missing else "")
        self.focus_first(self.hw_view)

    def act_close(self):
        self.show_page(getattr(self, "return_page", "welcome"))

    def page_install(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        # The slides of the product, while the system is copied.
        overlay = Gtk.Overlay()
        self.slide_image = Gtk.Image()
        self.slide_image.set_size_request(-1, 260)
        overlay.add(self.slide_image)
        words = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        words.set_valign(Gtk.Align.END)
        words.set_halign(Gtk.Align.START)
        words.set_margin_start(28)
        words.set_margin_bottom(22)
        words.set_margin_end(28)
        self.slide_title = label("", "slide-title")
        self.slide_text = label("", "slide-text")
        self.slide_text.set_max_width_chars(60)
        words.pack_start(self.slide_title, False, False, 0)
        words.pack_start(self.slide_text, False, False, 0)
        overlay.add_overlay(words)
        frame = Gtk.Box()
        frame.get_style_context().add_class("slide")
        frame.pack_start(overlay, True, True, 0)
        box.pack_start(frame, False, False, 0)
        self.slide_index = 0
        self.inst_step = label(f"Installing {self.wiz.product}.", "lead")
        box.pack_start(self.inst_step, False, False, 0)
        self.inst_bar = Gtk.ProgressBar()
        self.inst_bar.set_show_text(True)
        box.pack_start(self.inst_bar, False, False, 0)
        self.inst_result = label("")
        box.pack_start(self.inst_result, False, False, 0)
        expander = Gtk.Expander(label="Details")
        self.inst_details = expander
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

    def show_slide(self, index=None):
        if hasattr(self, "inst_details"):
            self.inst_details.set_label(i18n.t("installing.details", self.lang))
        slides = self.brand.slides(self.wiz.product, self.lang)
        if not slides:
            return False
        if index is not None:
            self.slide_index = index
        slide = slides[self.slide_index % len(slides)]
        width = max(self.stack.get_allocated_width(), 680)
        pix = svg_pixbuf(self.brand.svg(slide["image"]) if slide["image"] else None, width, 260, fill=True)
        if pix is not None:
            self.slide_image.set_from_pixbuf(pix)
        else:
            self.slide_image.clear()
        self.slide_title.set_text(slide["title"])
        self.slide_text.set_text(slide["text"])
        return True

    def next_slide(self):
        if not self.running:
            return False
        self.slide_index += 1
        self.show_slide()
        return True

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
        self.show_slide(0)
        GLib.timeout_add_seconds(8, self.next_slide)
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

def scroller_of(widget):
    """The scrolled window a widget is in, or None."""
    parent = widget.get_parent()
    while parent is not None:
        if isinstance(parent, Gtk.ScrolledWindow):
            return parent
        parent = parent.get_parent()
    return None


def follower_of(sw, page):
    """The next visible widget after the scroller in its box."""
    child = sw
    while child is not None and child is not page:
        parent = child.get_parent()
        if isinstance(parent, Gtk.Box):
            kids = [k for k in parent.get_children() if k.get_visible()]
            if child in kids and kids.index(child) + 1 < len(kids):
                return kids[kids.index(child) + 1]
        child = parent
    return None


def list_entry(win, page, widget):
    """What lists_of reports of one list-like widget."""
    sw = scroller_of(widget)
    own = sw is not None and sw is not win.page_scroller
    entry = {"kind": type(widget).__name__, "own_scroller": own,
             "name": getattr(sw, "list_name", "") if own else "",
             "height": sw.get_allocated_height() if own else widget.get_allocated_height(),
             "max": sw.get_max_content_height() if own else -1}
    nxt = follower_of(sw, page) if own else None
    if own:
        top = sw.translate_coordinates(win.page_scroller, 0, 0)
        entry["top"] = top[1] if top else -1
    if nxt is not None:
        pos = nxt.translate_coordinates(win.page_scroller, 0, 0)
        entry["follower"] = type(nxt).__name__
        entry["follower_bottom"] = (pos[1] + nxt.get_allocated_height()) if pos else -1
    return entry


def is_list_like(widget):
    return isinstance(widget, (Gtk.TreeView, Gtk.ListBox, Gtk.FlowBox)) or getattr(widget, "is_list", False)


def walk_lists(win, page, widget, found):
    """lists_of over a widget and its children."""
    if not widget.get_visible():
        return
    if getattr(widget, "not_a_list", None):
        found["exceptions"].append({"kind": type(widget).__name__, "reason": widget.not_a_list})
    elif is_list_like(widget):
        found["lists"].append(list_entry(win, page, widget))
        if isinstance(widget, Gtk.TreeView):
            return
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            walk_lists(win, page, child, found)


def lists_of(win):
    """Every list-like widget of the page shown (a TreeView, a ListBox or a
    FlowBox with rows, or a box marked as a list): whether it scrolls in a
    window of its own, how high that is, and whether the control after it
    is on the screen without scrolling the page.  The marked exceptions
    with their reasons."""
    page = win.stack.get_child_by_name(win.page)
    view_h = win.page_scroller.get_allocated_height()
    found = {"page": win.page, "page_height": page.get_allocated_height() if page else 0,
             "viewport": view_h, "lists": [], "exceptions": []}
    if page is not None:
        walk_lists(win, page, page, found)
    return found


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
            "type": self.page_welcome, "software": self.page_welcome,
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
        answers = self.answers
        dp = self.win.disk_page
        if dp.asks_usage():
            dp.usage_buttons[answers.get("usage", "together")].set_active(True)
        if answers.get("disk") in disk_index(dp.detail):
            dp.selected = [answers["disk"]]
            dp.fill_table()
            dp.fill_data()
            dp.refresh()
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
        answers = self.answers
        np = self.win.network_page
        mode = answers.get("network", "dhcp")
        if mode == "offline":
            np.offline.set_active(True)
        for tab in np.tabs:
            if tab.name == answers.get("net_if") and mode == "static":
                tab.v4[0].set_active_id("static")
                for key, entry in zip(("ipv4_addr", "ipv4_mask", "ipv4_gw"), tab.v4[1]):
                    entry.set_text(answers.get(key, ""))
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


def disk_index(detail):
    import diskplan
    return diskplan.disk_index(detail)


def apply_disk_state(win, state):
    """Set the disk page the way a person would: the mode, the disks, the
    layout and the options."""
    dp = win.disk_page
    # Every shot starts from a page without the choices of the shot before.
    dp.wipe = {}
    dp.partitions = []
    dp.data_disks = []
    dp.fill_partitions()
    dp.enc_check.set_active(False)
    dp.swap_enc.set_active(False)
    if "selected" in state:
        dp.selected = list(state["selected"])
    if "data_disks" in state:
        dp.data_disks = list(state["data_disks"])
    dp.fill_table()
    dp.fill_data()
    dp.mode_buttons[state.get("mode", "erase")].set_active(True)
    dp.usage = None
    dp.usage_none.set_active(True)
    if state.get("usage"):
        dp.usage_buttons[state["usage"]].set_active(True)
    if "separate" in state:
        dp.separate = dict(state["separate"])
        dp.fill_separate()
    if "layout" in state:
        dp.layout = state["layout"]
    if "filesystem" in state:
        dp.fs_combo.set_active_id(state["filesystem"])
    if state.get("encrypt"):
        dp.enc_check.set_active(True)
        dp.pass1.set_text(state.get("passphrase", ""))
        dp.pass2.set_text(state.get("passphrase", ""))
    if "swap_gb" in state:
        dp.swap.set_value(state["swap_gb"])
    if state.get("swap_encrypted"):
        dp.swap_enc.set_active(True)
    if "boot" in state:
        dp.boot_combo.set_active_id(state["boot"])
    for name, how in state.get("wipe", {}).items():
        dp.wipe[name] = how
    if "region_gb" in state:
        dp.size_scale.set_value(state["region_gb"])
    if "partitions" in state:
        dp.partitions = [dict(p) for p in state["partitions"]]
        dp.fill_partitions()
    # Advanced is open only where the shot asks for it (or for data disks).
    dp.advanced.set_expanded(bool(state.get("data_disks") or state.get("advanced")))
    dp.data_expander.set_expanded(bool(state.get("data_disks")))
    dp.refresh()


def render_pump(times=8):
    import time
    for _ in range(times):
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        time.sleep(0.03)


def render_save(win, outdir, name):
    render_pump()
    pixbuf = win.offscreen.get_pixbuf()
    ok, data = pixbuf.save_to_bufferv("png", [], [])
    if ok:
        W.write_new_file(os.path.join(outdir, name + ".png"), data)


def write_report(outdir, shot, kind, value, indent=None):
    """The JSON report of a shot: NAME.KIND.json."""
    import json
    W.write_new_file(os.path.join(outdir, f"{shot['name']}.{kind}.json"),
                     json.dumps(value, indent=indent).encode("utf-8"))


def render_show(win, shot, page, state):
    """Show the page of a shot, its disk page set first where it needs one."""
    if page == "summary" and shot.get("disk_state"):
        # The summary of a disk plan: set the disk page, take it.
        win.disk_page.mode_buttons[shot["disk_state"].get("mode", "erase")].set_active(True)
        win.show_page("disk")
        apply_disk_state(win, shot["disk_state"])
        win.disk_page.collect()
        win.wiz.answers.user_name = "tester"
        win.wiz.answers.full_name = "Test User"
    mode = state.get("mode")
    if mode and page in ("type", "disk"):
        win.disk_page.mode_buttons[mode].set_active(True)
    win.show_page(page)
    if page == "type" and mode:
        win.disk_page.mode_buttons[mode].set_active(True)
    if page == "disk":
        apply_disk_state(win, state)
    if state.get("locale") and state["locale"] in win.flag_buttons:
        win.flag_buttons[state["locale"]].set_active(True)


def flag_kind(button):
    """What a flag button shows: an image, a badge, or a text."""
    child = button.get_child()
    if isinstance(child, Gtk.Image):
        return "image"
    if child is not None and child.get_style_context().has_class("flag-badge"):
        return "badge"
    return "text"


def _report_encryption(win, shot, page, state, outdir):
    dp = win.disk_page
    write_report(outdir, shot, "encryption",
                 {"layout": dp.layout, "active": dp.enc_check.get_active(),
                  "sensitive": dp.enc_check.get_sensitive(),
                  "shown": dp.enc_check.get_visible(),
                  "passphrase_shown": any(w.get_visible() for w in dp.pass_row),
                  "note": dp.enc_note.get_text() if dp.enc_note.get_visible() else "",
                  "filesystems": [row[1] for row in dp.fs_combo.get_model()],
                  "data_layouts": [row[1] for row in dp.data_layout.get_model()],
                  "plan": dp.plan().get("encryption")})


def _report_usage(win, shot, page, state, outdir):
    dp = win.disk_page
    if state.get("press_next"):
        # Next before the question is answered, the way a person may.
        win.act_next()
    if state.get("choose"):
        dp.usage_buttons[state["choose"]].set_active(True)
    write_report(outdir, shot, "usage", {
        "model": dp.usage,
        "active": {k: b.get_active() for k, b in dp.usage_buttons.items()},
        "sensitive": {k: b.get_sensitive() for k, b in dp.usage_buttons.items()},
        "error": win.error_label.get_text(),
        "layout_note": dp.layout_more.get_visible(),
        "identity": win.identity_text,
        "problems": list(dp.errors)})


def _report_boot(win, shot, page, state, outdir):
    dp = win.disk_page
    model = dp.boot_combo.get_model()
    write_report(outdir, shot, "boot", {
        "offered": [row[1] for row in model] if model is not None else [],
        "active": dp.boot_combo.get_active_id(),
        "dropdown": dp.boot_combo.get_visible(),
        "fixed": dp.boot_fixed.get_text() if dp.boot_fixed.get_visible() else "",
        "plan": dp.plan().get("boot")})


def _report_busy(win, shot, page, state, outdir):
    # How the window lived through the slow probes of this shot.
    write_report(outdir, shot, "busy", win.busy_stats)


def _report_flags(win, shot, page, state, outdir):
    # What each flag button shows: an image, a badge, or a text.
    flags = [{"locale": locale, "country": button.flag_country, "kind": flag_kind(button)}
             for locale, button in win.flag_buttons.items()]
    write_report(outdir, shot, "flags", flags, indent=1)
    if page == "keyboard":
        win.show_page("keyboard")


REPORTS = {
    "encryption": _report_encryption,
    "usage": _report_usage,
    "boot": _report_boot,
    "busy": _report_busy,
    "flags": _report_flags,
}


def render_reports(win, shot, page, state, outdir):
    """The reports written before the page is laid out."""
    writer = REPORTS.get(state.get("report"))
    if writer is not None:
        writer(win, shot, page, state, outdir)


def render_focus(win, state):
    if state.get("zone"):
        select_name(win.tz_view, state["zone"])
    if state.get("focus") in getattr(win, "buttons", {}):
        button = win.buttons[state["focus"]]
        button.grab_focus()
        # An offscreen window is never the active window, so the toolkit
        # does not mark the focus itself: the picture marks it the way
        # an active window does.
        button.set_state_flags(Gtk.StateFlags.FOCUSED, False)


def render_install(win, state):
    win.show_slide(state["slide"])
    win.inst_bar.set_fraction(state.get("progress", 0.4))
    win.inst_bar.set_text(f"{int(state.get('progress', 0.4) * 100)}%")
    win.inst_step.set_text(state.get("step", "Writing the system files"))
    win.running = True
    win.set_actions()
    win.running = False


def render_users(win, u):
    win.user_entries["full_name"].set_text(u.get("full_name", ""))
    win.user_entries["user_name"].set_text(u.get("user", ""))
    win.user_entries["password"].set_text(u.get("password", ""))
    win.user_entries["confirm"].set_text(u.get("password", ""))
    if u.get("root") == "own":
        win.root_own.set_active(True)
        win.root_pw.set_text("r00t-pass")
        win.root_pw2.set_text("r00t-pass")
    win.autologin.set_active(bool(u.get("autologin")))


def render_network(win, n):
    import gui_network
    np = win.network_page
    np.notebook.set_current_page(n.get("tab", 0))
    tab = np.tabs[n.get("tab", 0)]
    if n.get("v4") == "static":
        tab.v4[0].set_active_id("static")
        for entry, value in zip(tab.v4[1], gui_network.EXAMPLE_IPV4):
            entry.set_text(value)
    if n.get("v6"):
        tab.v6[0].set_active_id(n["v6"])
    if n.get("dns"):
        np.dns.set_text(n["dns"])
    if "ssid_row" in n and tab.wifi:
        tab.view.get_selection().select_path(Gtk.TreePath.new_from_indices([n["ssid_row"]]))
        tab.psk.set_text("correct horse battery")
    np.update.set_active(True)


def render_software(win, state):
    sp = win.software_page
    if state.get("select_all"):
        sp.all_check.set_active(not sp.all_check.get_active())
    for ident in state.get("select", []):
        sp.checks[ident].set_active(True)
    if state.get("read"):
        sp.open_viewer(state["read"])


def render_page_state(win, page, state):
    """The controls of the page set the way the shot asks."""
    render_focus(win, state)
    if page == "install" and "slide" in state:
        render_install(win, state)
    if page == "users" and state.get("users"):
        render_users(win, state["users"])
    if page == "network" and state.get("network"):
        render_network(win, state["network"])
    if page == "summary" and state.get("typed"):
        win.sum_confirm.set_text(state["typed"])
    if page == "software":
        render_software(win, state)


def render_shot(win, shot, outdir, size):
    """Draw one shot; the names of the PNGs written."""
    page = shot.get("page", "welcome")
    state = shot.get("state", {})
    render_show(win, shot, page, state)
    render_reports(win, shot, page, state, outdir)
    render_page_state(win, page, state)
    win.offscreen.set_size_request(*size)
    win.offscreen.resize(*size)
    render_pump()
    if state.get("report") == "lists":
        # Measured once the page is laid out, before it is drawn.
        write_report(outdir, shot, "lists", lists_of(win), indent=1)
    render_save(win, outdir, shot["name"])
    written = [shot["name"]]
    if shot.get("full"):
        # The whole page: as tall as its content.
        child = win.stack.get_visible_child()
        _minimum, natural = child.get_preferred_height_for_width(size[0] - 300)
        chrome = size[1] - win.page_scroller.get_allocated_height()
        win.offscreen.set_size_request(size[0], max(size[1], natural + chrome + 20))
        render_pump()
        render_save(win, outdir, shot["name"] + "-full")
        written.append(shot["name"] + "-full")
    return written


def render(win, spec, outdir, size):
    """Draw pages in given states and write a PNG of each: the screen as
    it is, and the whole page when it scrolls."""
    import json
    with open(spec, encoding="utf-8") as stream:
        shots = json.load(stream)
    win.start()
    written = []
    for shot in shots:
        written += render_shot(win, shot, outdir, size)
    print("render: " + " ".join(written))
    return W.EXIT_OK


class KeyboardWalk:
    """Go from Welcome to Installing with the keyboard alone: synthesised
    key events (Tab, letters, Space, Alt and the underlined letter), never
    a click."""

    def __init__(self, win, answers, password):
        self.win = win
        self.answers = answers
        self.password = password
        self.top = win.offscreen or win
        display = Gdk.Display.get_default()
        self.keyboard = display.get_default_seat().get_keyboard()
        self.keymap = Gdk.Keymap.get_for_display(display)
        self.seen = []
        press, release = Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE
        mod1, meta = Gdk.ModifierType.MOD1_MASK, Gdk.ModifierType.META_MASK
        alt_l = Gdk.KEY_Alt_L
        send, key = self.send, self.key
        self.ways = [
            # Alt+letter with the Mod1 modifier on the letter.
            lambda k: key(k, mod1),
            # The Alt key itself first, the letter without a modifier (servers
            # that set no modifier on the next key), released in order.
            lambda k: (send(press, alt_l), send(press, k), send(release, k, mod1),
                       send(release, alt_l, mod1)),
            # Alt reported as Meta.
            lambda k: key(k, meta),
            # Alt released before the letter.
            lambda k: (send(press, alt_l), send(press, k, mod1), send(release, alt_l, mod1),
                       send(release, k)),
        ]
        self.used_ways = []
        self.pages = {
            "welcome": self.page_welcome,
            "keyboard": self.page_list, "timezone": self.page_list,
            "type": self.page_next, "network": self.page_next, "software": self.page_next,
            "disk": self.page_disk, "users": self.page_users,
            "summary": self.page_summary,
        }

    @staticmethod
    def pump():
        import time
        for _ in range(4):
            while Gtk.events_pending():
                Gtk.main_iteration_do(False)
            time.sleep(0.02)

    def send(self, etype, keyval, state=0):
        ok, entries = self.keymap.get_entries_for_keyval(keyval)
        event = Gdk.Event.new(etype)
        event.key.window = self.top.get_window()
        event.key.send_event = 1
        event.key.keyval = keyval
        event.key.state = state
        event.key.time = Gdk.CURRENT_TIME
        if ok:
            event.key.hardware_keycode = entries[0].keycode
        event.set_device(self.keyboard)
        Gtk.main_do_event(event)

    def key(self, keyval, state=0):
        self.send(Gdk.EventType.KEY_PRESS, keyval, state)
        self.send(Gdk.EventType.KEY_RELEASE, keyval, state)
        self.pump()

    def type_text(self, text):
        for ch in text:
            self.key(Gdk.unicode_to_keyval(ord(ch)))

    def alt(self, letter):
        way = self.ways[len(self.used_ways) % len(self.ways)]
        self.used_ways.append(way)
        way(Gdk.unicode_to_keyval(ord(letter)))
        self.pump()

    def focused(self):
        return self.top.get_focus()

    def page_welcome(self, _page):
        self.alt("i")                       # _Install ExampleBSD

    def page_list(self, page):
        # The list has the focus; Return on its row goes on.
        if not isinstance(self.focused(), Gtk.TreeView):
            raise SystemExit(f"keyboard: the list of {page} does not have the focus")
        self.key(Gdk.KEY_Return)

    def page_next(self, _page):
        self.alt("n")

    def page_disk(self, _page):
        dp = self.win.disk_page
        if dp.asks_usage() and dp.usage is None:
            if self.focused() is not dp.usage_buttons["together"]:
                raise SystemExit("keyboard: the disk question does not have the focus")
            self.key(Gdk.KEY_space)         # Use the disks together
        # Return on the row of a disk goes on.
        dp.view.grab_focus()
        self.key(Gdk.KEY_Return)

    def page_users(self, _page):
        # The focus is on the full name; Tab goes from field to field.
        if self.focused() is not self.win.user_entries["full_name"]:
            raise SystemExit("keyboard: the full name does not have the focus")
        self.type_text(self.answers.get("full_name", "Test User"))
        self.key(Gdk.KEY_Tab)
        self.type_text(self.answers.get("user", "tester"))
        self.key(Gdk.KEY_Tab)
        self.type_text(self.password)
        self.key(Gdk.KEY_Tab)
        self.type_text(self.password)
        self.alt("n")

    def page_summary(self, _page):
        self.alt("i")                       # _Install

    def run(self):
        win = self.win
        win.start()
        self.pump()
        for _ in range(30):
            page = win.page
            self.seen.append(page)
            if page == "install":
                break
            handler = self.pages.get(page)
            if handler is None:
                raise SystemExit(f"keyboard: no way on from {page}")
            handler(page)
            if win.page == page:
                raise SystemExit(f"keyboard: stuck on {page}: {win.error_label.get_text()}")
        while win.running:
            Gtk.main_iteration_do(True)
        used, ways = self.used_ways, self.ways
        print("keyboard: pages " + " ".join(self.seen))
        print(f"keyboard: Alt and a letter, {len(used)} times, in {min(len(used), len(ways))} ways")
        print(f"keyboard: full name {win.wiz.answers.full_name!r}")
        return W.EXIT_OK if "install" in self.seen else W.EXIT_FAILED


def keyboard_walk(win, answers, password):
    """Go from Welcome to Installing with the keyboard alone: synthesised
    key events (Tab, letters, Space, Alt and the underlined letter), never
    a click.  For computers without a pointer (a virtual machine whose
    tablet the system does not know)."""
    return KeyboardWalk(win, answers, password).run()


class UsageError(Exception):
    """An option of the command line that cannot be read."""


def option_value(name):
    """The value after an option of the command line."""
    return ARGS[ARGS.index(name) + 1]


def option_size():
    """--size WIDTHxHEIGHT, or None without it."""
    if "--size" not in ARGS:
        return None
    try:
        w, h = option_value("--size").lower().split("x")
        return (int(w), int(h))
    except (IndexError, ValueError):
        raise UsageError("installer-gui: --size takes WIDTHxHEIGHT\n") from None


def apply_text_scale():
    """For the smoke run: larger text, the way a screen with more dots
    per inch or a larger font shows it."""
    if "--text-scale" not in ARGS or "--smoke" not in ARGS:
        return
    try:
        factor = float(option_value("--text-scale"))
    except (IndexError, ValueError):
        raise UsageError("installer-gui: --text-scale takes a number\n") from None
    Gtk.Settings.get_default().set_property("gtk-xft-dpi", int(96 * 1024 * factor))


def read_answers(option):
    import json
    with open(option_value(option), encoding="utf-8") as stream:
        return json.load(stream)


def run_interactive(win):
    """The installer for a person, until it quits or a signal ends it."""
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


def run_window(win, size):
    """The run the command line asks for: a test walk, the shots, or the installer."""
    if "--keyboard-walk" in ARGS:
        answers = read_answers("--keyboard-walk")
        return keyboard_walk(win, answers, sys.stdin.readline().rstrip("\n"))
    if "--render" in ARGS:
        spec = option_value("--render")
        outdir = option_value("--screenshots") if "--screenshots" in ARGS else "."
        return render(win, spec, outdir, size or (1024, 768))
    if "--smoke" in ARGS:
        answers = read_answers("--smoke")
        password = sys.stdin.readline().rstrip("\n")
        shots = option_value("--screenshots") if "--screenshots" in ARGS else ""
        return smoke(win, answers, password, shots)
    return run_interactive(win)


def main():
    windowed = "--windowed" in ARGS or "--smoke" in ARGS or "--render" in ARGS or "--keyboard-walk" in ARGS
    wiz = W.Wizard(ROOT)
    try:
        size = option_size()
        apply_text_scale()
    except UsageError as error:
        sys.stderr.write(str(error))
        return 2
    offscreen = "--screenshots" in ARGS or "--render" in ARGS or "--keyboard-walk" in ARGS
    win = InstallerWindow(wiz, windowed=windowed, offscreen=offscreen, size=size)
    win.show_all()
    if win.offscreen is not None:
        win.offscreen.show_all()
    try:
        return run_window(win, size)
    finally:
        wiz.close()


if __name__ == "__main__":
    sys.exit(main())

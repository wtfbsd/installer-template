# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""A list that can grow long scrolls in a window of its own.

A list packed straight into a page grows the page, and only the scroller
of the whole page keeps the buttons on the screen; the control that
follows the list (the Wi-Fi passphrase, the button that adds a partition)
moves out of sight.  scrolled() gives a list its own scroller: at least
rows_min and at most rows_max rows high, scrolled from the keyboard, the
row with the focus (or the selected row) kept in view.

A widget that looks like a list but lays out a few controls (cards,
badges, a row of buttons) is marked not_a_list with the reason; the tests
walk every page and fail on a list without its own scroller.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

ROW_PX = 28


def scrolled(widget, rows_min=4, rows_max=10, row_px=ROW_PX, name=""):
    """The widget (a TreeView, or a Box of rows) in a scroller of its own."""
    sw = Gtk.ScrolledWindow()
    sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    sw.set_shadow_type(Gtk.ShadowType.IN)
    sw.set_propagate_natural_height(True)
    sw.set_min_content_height(rows_min * row_px)
    sw.set_max_content_height(rows_max * row_px)
    if isinstance(widget, Gtk.TreeView):
        sw.add(widget)
        # The selected row stays in view.
        widget.get_selection().connect(
            "changed", lambda sel: _show_selected(widget, sel))
    else:
        # A box of rows: the control with the focus is kept in view.
        sw.add(widget)
        widget.set_focus_vadjustment(sw.get_vadjustment())
    widget.is_list = True
    sw.list_scroller = True
    sw.list_name = name
    return sw


def _show_selected(view, selection):
    model, it = selection.get_selected() if selection.get_mode() != Gtk.SelectionMode.MULTIPLE \
        else (None, None)
    if model is not None and it is not None:
        view.scroll_to_cell(model.get_path(it), None, False, 0, 0)


def not_a_list(widget, reason):
    """Mark a FlowBox or a ListBox that lays out a few controls."""
    widget.not_a_list = reason
    return widget

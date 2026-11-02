# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The eye of a password field: it shows and hides what was typed.

Every password and passphrase entry of the graphical front end gets one
(add_eye): the secondary icon of the entry, an eye, and Ctrl+Shift+H from
the keyboard while the field has the focus.  Showing one field shows that
field only; hide_all hides every field again (a new page is shown).
"""

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402

SHOW = "Show the password"
HIDE = "Hide the password"
_ENTRIES = []


def _set(entry, shown):
    entry.set_visibility(shown)
    entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,
                                  "view-conceal-symbolic" if shown else "view-reveal-symbolic")
    entry.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, HIDE if shown else SHOW)


def toggle(entry):
    """Show the field when it is hidden, hide it when it is shown."""
    _set(entry, not entry.get_visibility())


def _on_key(entry, event):
    state = event.state & Gtk.accelerator_get_default_mod_mask()
    if event.keyval in (Gdk.KEY_h, Gdk.KEY_H) and \
            state == Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK:
        toggle(entry)
        return True
    return False


def add_eye(entry):
    """The eye on a password entry (hidden to begin with)."""
    entry.set_icon_activatable(Gtk.EntryIconPosition.SECONDARY, True)
    entry.set_icon_sensitive(Gtk.EntryIconPosition.SECONDARY, True)
    _set(entry, False)
    entry.connect("icon-press", lambda e, pos, _ev: toggle(e)
                  if pos == Gtk.EntryIconPosition.SECONDARY else None)
    entry.connect("key-press-event", _on_key)
    _ENTRIES.append(entry)
    return entry


def has_eye(entry):
    return entry in _ENTRIES and \
        entry.get_icon_name(Gtk.EntryIconPosition.SECONDARY) in ("view-reveal-symbolic",
                                                                  "view-conceal-symbolic")


def hide_all():
    """Every password field hidden again (a page was left)."""
    for entry in _ENTRIES:
        _set(entry, False)

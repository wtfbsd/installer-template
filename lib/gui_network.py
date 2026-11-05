# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The page "Network": every adapter in a tab of its own.

Each adapter: IPv4 automatic (DHCP), manual or off; IPv6 automatic
(SLAAC), manual or off; a Wi-Fi adapter also lists the networks in reach
and takes the network to join with its security and passphrase.  Below the
tabs: the resolvers (empty: from DHCP), installing without a network, the
online check and updating the packages after the installation (only when
the machine is online).  Every value is checked by lib/netplan.py, the same
code the backend and the root helper run.
"""

import ipaddress

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # noqa: E402

try:
    gi.require_version("Atk", "1.0")
    from gi.repository import Atk  # noqa: E402
except (ImportError, ValueError):
    Atk = None

import netplan as N  # noqa: E402
from gui_lists import scrolled  # noqa: E402
import gui_reveal  # noqa: E402

# The examples in the empty fields: the documentation network of RFC 5737
# (192.0.2.0/24), its netmask derived from it, not typed as an address.
EXAMPLE_IPV4_NET = ipaddress.ip_network("192.0.2.0/24")
EXAMPLE_IPV4 = (str(EXAMPLE_IPV4_NET[10]), str(EXAMPLE_IPV4_NET.netmask), str(EXAMPLE_IPV4_NET[1]))


def linked(text, control, css="field-label"):
    """The label of a field, linked to its control (as lib/gui.py
    field_label): a screen reader names the field by it."""
    widget = lbl(text, css, wrap=False)
    widget.set_mnemonic_widget(control)
    if Atk is not None:
        own = widget.get_accessible()
        other = control.get_accessible()
        own.add_relationship(Atk.RelationType.LABEL_FOR, other)
        other.add_relationship(Atk.RelationType.LABELLED_BY, own)
    return widget


def lbl(text="", css=None, wrap=True):
    widget = Gtk.Label(label=text)
    widget.set_xalign(0.0)
    widget.set_line_wrap(wrap)
    widget.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for name in (css or "").split():
        widget.get_style_context().add_class(name)
    return widget


class AdapterTab:
    """The settings of one adapter."""

    def __init__(self, page, item, networks):
        self.page = page
        self.name = item.name
        self.wifi = N.is_wifi(item.name)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.widget = box
        grid = Gtk.Grid(column_spacing=12, row_spacing=6)
        box.pack_start(grid, False, False, 0)
        self.v4 = self.family(grid, 0, "IPv4", [("dhcp", "Automatic (DHCP)"), ("static", "Manual"),
                                                ("off", "Off")],
                              tuple(zip(("Address", "Netmask", "Gateway"), EXAMPLE_IPV4)))
        self.v6 = self.family(grid, 4, "IPv6", [("slaac", "Automatic (SLAAC)"), ("static", "Manual"),
                                                ("off", "Off")],
                              (("Address", "2001:db8::10"), ("Prefix length", "64"),
                               ("Gateway", "2001:db8::1")), top=16)
        if self.wifi:
            box.pack_start(lbl("Wi-Fi networks in reach", "field-label"), False, False, 0)
            self.store = Gtk.ListStore(str, str, str)
            for net in networks:
                self.store.append([net["ssid"], net["security"].upper(), f"{net['signal']} %"])
            self.view = Gtk.TreeView(model=self.store)
            for index, title in enumerate(("Network", "Security", "Signal")):
                column = Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index)
                column.set_expand(index == 0)
                self.view.append_column(column)
            self.view.get_selection().connect("changed", self.on_network)
            # Many networks in reach: the list scrolls, the passphrase below
            # it stays in sight.
            box.pack_start(scrolled(self.view, 3, 6, name="wifi"), False, False, 0)
            row = Gtk.Grid(column_spacing=12, row_spacing=6)
            self.ssid = Gtk.Entry(placeholder_text="the name, also of a hidden network")
            row.attach(self.page.label(linked("Network name", self.ssid)), 0, 0, 1, 1)
            self.ssid.set_hexpand(True)
            row.attach(self.ssid, 1, 0, 1, 1)
            row.attach(self.page.label(lbl("Security", "field-label", wrap=False)), 0, 1, 1, 1)
            self.security = Gtk.ComboBoxText()
            for ident, title in (("wpa2", "WPA2"), ("wpa3", "WPA3"), ("open", "Open (no password)")):
                self.security.append(ident, title)
            self.security.set_active_id("wpa2")
            row.attach(self.security, 1, 1, 1, 1)
            self.psk = Gtk.Entry(visibility=False)
            row.attach(self.page.label(linked("Passphrase", self.psk)), 0, 2, 1, 1)
            self.psk.set_input_purpose(Gtk.InputPurpose.PASSWORD)
            gui_reveal.add_eye(self.psk)
            row.attach(self.psk, 1, 2, 1, 1)
            box.pack_start(row, False, False, 0)
            # The fields of the network stand in one column, like the
            # fields of the page around them.
            self.page.win.cap_form(row)
            box.pack_start(lbl("The installed system joins this network when it starts. The "
                               "Wi-Fi firmware is already on the media.", "muted"), False, False, 0)
            # A Wi-Fi adapter: the network to join comes first, its
            # addresses after it (they keep their automatic defaults).
            box.reorder_child(grid, -1)
        # The fields of the adapter stand in one column, like the fields of
        # the page around them.
        self.page.win.cap_form(grid)

    def family(self, grid, row, title, modes, fields, top=0):
        head = lbl(title, "field-label", wrap=False)
        head.set_margin_top(top)
        grid.attach(self.page.label(head), 0, row, 1, 1)
        combo = Gtk.ComboBoxText()
        for ident, text in modes:
            combo.append(ident, text)
        combo.set_active_id(modes[0][0])
        # The room above the row belongs to the label and to the field
        # beside it: they stand in the middle of it together.
        combo.set_margin_top(top)
        grid.attach(combo, 1, row, 1, 1)
        entries = []
        for i, (name, hint) in enumerate(fields, start=1):
            entry = Gtk.Entry(placeholder_text=f"for example {hint}")
            # Shown as "Address", named "IPv4 Address" to a screen reader.
            name_label = linked(name, entry, css=None)
            if Atk is not None:
                name_label.get_accessible().set_name(f"{title} {name}")
            grid.attach(self.page.label(name_label), 0, row + i, 1, 1)
            entry.set_hexpand(True)
            grid.attach(entry, 1, row + i, 1, 1)
            entries.append(entry)

        def gate(*_a):
            # A manual address is only typeable while Manual is chosen; what
            # was typed stays.
            for entry in entries:
                entry.set_sensitive(combo.get_active_id() == "static")
        combo.connect("changed", gate)
        gate()
        return combo, entries

    def on_network(self, selection):
        model, it = selection.get_selected()
        if it is None:
            return
        self.ssid.set_text(model[it][0])
        self.security.set_active_id(model[it][1].lower())

    def collect(self):
        """(ipv4, ipv6, wifi) of the adapter, or a problem."""
        combo, entries = self.v4
        mode = combo.get_active_id()
        v4 = None
        if mode == "dhcp":
            v4 = "dhcp"
        elif mode == "static":
            addr, mask, gw = (e.get_text().strip() for e in entries)
            v4 = f"{addr}/{mask}:{gw}"
        combo6, entries6 = self.v6
        mode6 = combo6.get_active_id()
        v6 = None
        if mode6 == "slaac":
            v6 = "slaac"
        elif mode6 == "static":
            addr, prefix, gw = (e.get_text().strip() for e in entries6)
            v6 = f"{addr}/{prefix}:{gw}"
        wifi = None
        if self.wifi and self.ssid.get_text().strip():
            wifi = {"if": self.name, "ssid": self.ssid.get_text().strip(),
                    "security": self.security.get_active_id(),
                    "psk": self.psk.get_text() if self.security.get_active_id() != "open" else ""}
        return v4, v6, wifi


class NetworkPage:
    def __init__(self, win):
        self.win = win
        self.wiz = win.wiz
        self.tabs = []
        # The labels of the fields of the page stand in one column: the
        # fields of the page and of every adapter start at the same place.
        self.labels = Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)

    def label(self, widget):
        """A label of a field: it takes the width of the labels of the
        page, so the fields stand in one column."""
        self.labels.add_widget(widget)
        return widget

    def build(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.text = lbl("")
        box.pack_start(self.text, False, False, 0)
        # One adapter at a time.  The stack is as tall as the adapter it
        # shows, not as tall as the tallest of them: the controls below
        # stay on the screen.
        self.stack = Gtk.Stack()
        self.stack.set_vhomogeneous(False)
        self.stack.set_hhomogeneous(False)
        self.switcher = Gtk.StackSwitcher()
        self.switcher.set_stack(self.stack)
        box.pack_start(self.switcher, False, False, 0)
        box.pack_start(self.stack, False, False, 0)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.dns = Gtk.Entry(placeholder_text="empty: from DHCP; or 192.0.2.53, 2001:db8::53")
        grid.attach(self.label(linked("Resolvers (DNS)", self.dns)), 0, 0, 1, 1)
        self.dns.set_hexpand(True)
        grid.attach(self.dns, 1, 0, 1, 1)
        self.win.cap_form(grid)
        box.pack_start(grid, False, False, 0)
        self.offline = Gtk.CheckButton(label="Install without a network (no adapter is set up)")
        self.offline.connect("toggled", lambda *_a: self.stack.set_sensitive(
            not self.offline.get_active()))
        box.pack_start(self.offline, False, False, 0)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        check = Gtk.Button(label="Check the connection")
        check.connect("clicked", lambda *_a: self.load())
        row.pack_start(check, False, False, 0)
        self.online = lbl("", wrap=False)
        row.pack_start(self.online, False, False, 0)
        box.pack_start(row, False, False, 0)
        self.update = Gtk.CheckButton(label="Update the packages after the installation")
        box.pack_start(self.update, False, False, 0)
        return box

    def load(self):
        items, wifi, online, err = self.wiz.network_report()
        current = self.stack.get_visible_child_name()
        for child in self.stack.get_children():
            self.stack.remove(child)
        self.tabs = []
        for item in items:
            tab = AdapterTab(self, item, wifi.get(item.name, []))
            title = f"{item.name} — {'Wi-Fi' if tab.wifi else item.descr}"
            self.stack.add_titled(tab.widget, title, title)
            self.tabs.append(tab)
        self.stack.show_all()
        self.switcher.show_all()
        if current in [c.get_name() for c in self.stack.get_children()]:
            self.stack.set_visible_child_name(current)
        if items:
            self.text.set_text(f"Set up how {self.wiz.product} connects, one adapter at a time.")
        else:
            self.text.set_text("No network adapters found. The installation can continue "
                               "without a network." + (f" ({err})" if err else ""))
            self.offline.set_active(True)
        self.online.set_text("This machine is online." if online else
                             "This machine is not online now.")
        self.update.set_sensitive(online)
        if not online:
            self.update.set_active(False)

    def collect(self):
        a = self.wiz.answers
        a.net_ipv4, a.net_ipv6, a.wifi = {}, {}, None
        if self.offline.get_active():
            a.network_mode, a.net_if = "offline", ""
            a.dns = []
            a.update_after = False
            return None
        self.collect_tabs(a)
        dns = [s.strip() for s in self.dns.get_text().replace(" ", ",").split(",") if s.strip()]
        a.dns = dns
        a.update_after = self.update.get_active()
        problems = self.problems_of(a, dns)
        if problems:
            return problems[0]
        self.collect_first(a)
        return None

    def collect_tabs(self, a):
        """The answers of every adapter tab."""
        for tab in self.tabs:
            v4, v6, wifi = tab.collect()
            if v4:
                a.net_ipv4[tab.name] = v4
            if v6:
                a.net_ipv6[tab.name] = v6
            if wifi:
                a.wifi = wifi

    @staticmethod
    def problems_of(a, dns):
        """What lib/netplan.py refuses in the answers, in order."""
        problems = []
        if a.net_ipv4:
            problems += N.check_ipv4(";".join(f"{k}:{v}" for k, v in a.net_ipv4.items()))
        if a.net_ipv6:
            problems += N.check_ipv6(";".join(f"{k}:{v}" for k, v in a.net_ipv6.items()))
        if dns:
            problems += N.check_dns(",".join(dns))
        if a.wifi and a.wifi["security"] != "open" and not 8 <= len(a.wifi["psk"]) <= 63:
            problems.append("the Wi-Fi passphrase has 8 to 63 characters")
        return problems

    @staticmethod
    def collect_first(a):
        """The answers the text front end writes too: the first adapter."""
        first = next(iter(a.net_ipv4), "")
        a.net_if = first
        a.network_mode = "dhcp" if not first or a.net_ipv4[first] == "dhcp" else "static"
        if a.network_mode == "static":
            addr_mask, _sep, gw = a.net_ipv4[first].partition(":")
            a.ipv4_addr, _s, a.ipv4_mask = addr_mask.partition("/")
            a.ipv4_gw = gw

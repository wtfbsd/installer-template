# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the network answers (lib/netplan.py): every adapter's IPv4
# and IPv6, the resolvers and the Wi-Fi network, checked, and the options of
# the install command built from them.

import json
import os
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import netplan as N  # noqa: E402


class ListsTest(unittest.TestCase):
    def test_good_lists(self):
        self.assertEqual(N.check_ipv4("em0:dhcp;em1:192.0.2.10/255.255.255.0:192.0.2.1"), [])
        self.assertEqual(N.check_ipv4("em1:192.0.2.10/255.255.255.0:"), [])
        self.assertEqual(N.check_ipv6("em0:slaac;em1:2001:db8::10/64:2001:db8::1"), [])
        self.assertEqual(N.check_dns("192.0.2.53,2001:db8::53"), [])

    def test_bad_lists(self):
        for bad in ("em0:dhcp;em0:dhcp", "EM0:dhcp", "em0:192.0.2.300/255.255.255.0:",
                    "em0:192.0.2.1/24:", "em0;id:dhcp", "em0:dhcp;", "em0:static"):
            with self.subTest(bad):
                self.assertNotEqual(N.check_ipv4(bad), [])
        for bad in ("em0:2001:db8::10/129:", "em0:192.0.2.1/24:", "em0:2001:db8::zz/64:",
                    "em0:slaac;em0:slaac"):
            with self.subTest(bad):
                self.assertNotEqual(N.check_ipv6(bad), [])
        for bad in ("192.0.2.53;rm", "not-an-address", ",".join(["192.0.2.1"] * 9)):
            with self.subTest(bad):
                self.assertNotEqual(N.check_dns(bad), [])

    def test_the_options_of_the_install_command(self):
        argv = N.argv({"NET_IPV4_LIST": "em0:dhcp;em1:192.0.2.10/255.255.255.0:192.0.2.1",
                       "NET_IPV6_LIST": "em0:slaac", "DNS_SERVERS": "192.0.2.53",
                       "UPDATE_AFTER": "yes"})
        self.assertEqual(argv, ["-N", "em0:dhcp", "-N", "em1:192.0.2.10/255.255.255.0:192.0.2.1",
                                "-6", "em0:slaac", "-D", "192.0.2.53", "-U"])
        self.assertEqual(N.argv({}), [])


class WifiTest(unittest.TestCase):
    def write(self, data, mode=0o600):
        fd, path = tempfile.mkstemp()
        os.write(fd, json.dumps(data).encode())
        os.close(fd)
        os.chmod(path, mode)
        self.addCleanup(os.unlink, path)
        return path

    def test_a_good_network(self):
        self.assertEqual(N.check_wifi(self.write(
            {"if": "iwm0", "ssid": "Example Net", "security": "wpa2", "psk": "correct horse"})), [])
        self.assertEqual(N.check_wifi(self.write(
            {"if": "iwm0", "ssid": "Cafe", "security": "open", "psk": ""})), [])

    def test_bad_networks(self):
        for data in ({"if": "iwm0", "ssid": "", "security": "wpa2", "psk": "12345678"},
                     {"if": "iwm0", "ssid": "x" * 33, "security": "wpa2", "psk": "12345678"},
                     {"if": "iwm0", "ssid": "Net", "security": "wpa2", "psk": "short"},
                     {"if": "iwm0", "ssid": "Net", "security": "wep", "psk": "12345678"},
                     {"if": "iwm0", "ssid": "Net", "security": "wpa2", "psk": "a\nb12345678"},
                     {"if": "Iwm0", "ssid": "Net", "security": "open", "psk": ""},
                     {"if": "iwm0", "ssid": "Net", "security": "open", "psk": "", "extra": 1}):
            with self.subTest(data):
                self.assertNotEqual(N.check_wifi(self.write(data)), [])
        self.assertNotEqual(N.check_wifi(self.write(
            {"if": "iwm0", "ssid": "Net", "security": "open", "psk": ""}, 0o644)), [])

    def test_scan_results_are_parsed(self):
        nets = N.parse_scan("Example Net|wpa2|78\nOpen Cafe|open|40\n|wpa2|10\nbad line\n")
        self.assertEqual([n["ssid"] for n in nets], ["Example Net", "Open Cafe"])


if __name__ == "__main__":
    unittest.main()


class ResolverScopeTest(unittest.TestCase):
    """An IPv6 resolver may name its link (%em0), and nothing else: the
    text after % reaches the command line of the install command."""

    def test_the_scope_is_the_name_of_an_adapter(self):
        self.assertEqual(N.check_dns("2001:db8::53%em0"), [])
        for bad in ("2001:db8::53%$(id) x;y", "2001:db8::53%", "2001:db8::53%em0 x", "2001:db8::53%../x", "2001:db8::53%%em0"):
            with self.subTest(bad):
                self.assertTrue(N.check_dns(bad))

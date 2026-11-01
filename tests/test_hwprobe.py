# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the hardware probe (lib/hwprobe.py): the outputs of the real
# tools of FreeBSD 16, NetBSD 11, OpenBSD 8.0 and DragonFly 6.4.2 on a
# virtual machine (tests/fixtures/hw-captures; the MAC addresses moved to
# the documentation range) are replayed.  The machine has a virtio network
# adapter, a framebuffer without a DRM driver, a USB tablet and the PS/2
# keyboard and mouse; no Wi-Fi, no sound, no Bluetooth.

import pathlib
import re
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import hwprobe as H  # noqa: E402

CAPTURES = ROOT / "tests" / "fixtures" / "hw-captures"


def report(os_name, directory=None):
    return H.probe(os_name, H.Replay(str(directory or CAPTURES / os_name)))


def classes(rep):
    return sorted({(d["class"], d["driver"]) for d in rep["devices"]})


class CapturedTest(unittest.TestCase):
    def test_freebsd(self):
        rep = report("freebsd")
        self.assertEqual(classes(rep), [("Ethernet", "vtnet0"), ("GPU", "vgapci0"), ("Input", "atkbd0"),
                                        ("Input", "hms0"), ("Input", "psm0")])
        gpu = [d for d in rep["devices"] if d["class"] == "GPU"][0]
        # vgapci0 has a drmn0 child without a driver: no DRM driver.
        self.assertEqual(gpu["status"], "basic display (no DRM driver)")
        self.assertEqual(gpu["name"], "PCI fb5d:40fb display")
        self.assertEqual(rep["unavailable"], ["the firmware directory /usr/local/share/firmware"])

    def test_netbsd(self):
        rep = report("netbsd")
        self.assertEqual(classes(rep), [("Ethernet", "vioif0"), ("GPU", "vga0"), ("Input", "pckbd0"),
                                        ("Input", "pms0")])
        self.assertEqual(rep["unavailable"], [])

    def test_openbsd_without_pcidump(self):
        rep = report("openbsd")
        self.assertEqual(classes(rep), [("Ethernet", "vio0"), ("GPU", "vga1"), ("Input", "pckbd0")])
        eth = [d for d in rep["devices"] if d["class"] == "Ethernet"][0]
        self.assertEqual(eth["name"], "Qumranet Virtio Network")
        self.assertEqual(rep["unavailable"], ["the PCI devices (pcidump); the kernel messages are used"])

    def test_dragonfly(self):
        rep = report("dragonfly")
        self.assertEqual(classes(rep), [("Ethernet", "vtnet0"), ("GPU", "vgapci0"), ("Input", "atkbd0"),
                                        ("Input", "psm0")])
        gpu = [d for d in rep["devices"] if d["class"] == "GPU"][0]
        # A drm0 place, no DRM driver (DragonFly's devinfo has no descriptions).
        self.assertEqual(gpu["status"], "basic display (no DRM driver)")
        self.assertEqual(rep["unavailable"], ["the firmware directory /boot/firmware /boot/modules"])

    def test_nothing_captured_is_not_an_error(self):
        empty = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, empty)
        for os_name in ("freebsd", "netbsd", "openbsd", "dragonfly"):
            with self.subTest(os_name):
                rep = report(os_name, empty)
                self.assertEqual(rep["devices"], [])
                self.assertTrue(rep["unavailable"])

    def test_only_reading_tools(self):
        for os_name in ("freebsd", "netbsd", "openbsd", "dragonfly"):
            runner = H.Replay(str(CAPTURES / os_name))
            H.probe(os_name, runner)
            for key in runner.keys:
                self.assertRegex(key, r"^(pciconf_-lv|devinfo_-v|usbconfig_list|sysctl_net\.wlan\.devices|"
                                      r"ls_.*|drvctl_-lt|pcictl_pci0_list_-N|usbdevs_-v|pcidump_-v|dmesg)$")
        for paths in H.TOOLS.values():
            self.assertTrue(all(p.startswith("/") for p in paths))


class FirmwareTest(unittest.TestCase):
    def test_wifi_firmware(self):
        files = (CAPTURES / "freebsd" / "ls_-R_boot_firmware.out").read_text().split()
        self.assertEqual(H.firmware_state("iwlwifi0", "Wi-Fi", files), "present")
        self.assertEqual(H.firmware_state("iwm0", "Wi-Fi", files), "present")  # iwm7260fw
        self.assertEqual(H.firmware_state("otus0", "Wi-Fi", files), "missing")
        self.assertEqual(H.firmware_state("iwm0", "Wi-Fi", None), "unknown")
        self.assertEqual(H.firmware_state("em0", "Ethernet", files), "not needed")
        nb = (CAPTURES / "netbsd" / "ls_-R_libdata_firmware.out").read_text().split()
        self.assertEqual(H.firmware_state("iwm0", "Wi-Fi", nb), "present")
        self.assertEqual(H.firmware_state("amdgpu0", "GPU", nb), "present")

    def test_a_card_without_a_driver(self):
        text = ("none3@pci0:0:20:3:\tclass=0x028000 rev=0x00 hdr=0x00 vendor=0x8086 device=0x2723 "
                "subvendor=0x8086 subdevice=0x0084\n    vendor     = 'Intel Corporation'\n"
                "    device     = 'Wi-Fi 6 AX200'\n    class      = network\n")
        dev = H.parse_pciconf(text)[0]
        self.assertIsNone(dev["driver"])
        self.assertEqual(H.pci_class(dev["class"], ""), "Wi-Fi")


# The patterns the line parsers replaced (they backtrack super-linearly);
# a parser gives what its pattern gave, on every line of the captures.
OLD_BASE = re.compile(r"\d+$")
OLD_PCICONF = re.compile(r"^(\w+?)(\d+)?@pci[\d:]+:\s+class=0x([0-9a-f]{6})")
OLD_PCICTL = re.compile(r"^[\d:]+: (.*) \(([^)]*)\)(?: \[(\w+)\])?$")
OLD_DMESG_PCI = re.compile(r'^(\w+?\d+) at pci\d+ dev \d+ function \d+ (?:"([^"]*)"|(.*?) rev)')
OLD_DMESG_AT = re.compile(r'^(\w+?\d+) at (\w+?\d+)(?: dev \d+ function \d+ (?:"([^"]*)"|(.*?) rev))?')


def capture_lines(os_name, key):
    return (CAPTURES / os_name / f"{key}.out").read_text(encoding="utf-8").split("\n")


class LineParserTest(unittest.TestCase):
    def test_the_unit_goes_as_before(self):
        for name in ("em0", "vgapci12", "drm", "", "0", "a1b2", "x\u0663", "pci0\n", "a\n\n", "12\n"):
            self.assertEqual(H.base(name), OLD_BASE.sub("", name), repr(name))

    def test_a_device_of_pciconf_goes_as_before(self):
        lines = capture_lines("freebsd", "pciconf_-lv") + capture_lines("dragonfly", "pciconf_-lv")
        lines += ["none12@pci0:0:2:0:\tclass=0x030000", "7@pci0:0:1:0: class=0x020000",
                  "em0@pci:: class=0x020000", "em0@pci0: class=0x020000", "em0@pci0:0:1:0:xclass=0x020000",
                  "a\u0663@pci0:0:1:0: class=0x020000", "em0@pci0:0:1:0: :  class=0x020000"]
        found = 0
        for line in lines:
            m = OLD_PCICONF.match(line)
            want = m and (m.group(1), m.group(1) + (m.group(2) or ""), int(m.group(3), 16))
            self.assertEqual(H.pciconf_head(line), want or None, line)
            found += bool(want)
        self.assertGreater(found, 3)

    def test_a_line_of_pcictl_goes_as_before(self):
        lines = [raw.strip() for raw in capture_lines("netbsd", "pcictl_pci0_list_-N")]
        lines += ["000:02:0: A (B) (display) [vga0]", "0: a (b)", "000:02:0: a (b)c)",
                  "000:02:0: a (b) [v ga]", "000:02:0: (b)", "000:02:0: a ()", "000:02:0: a (x) [y])",
                  ":: a (b) []"]
        found = 0
        for line in lines:
            m = OLD_PCICTL.match(line)
            want = m and (m.group(1), m.group(2), m.group(3) or "")
            self.assertEqual(H.pcictl_line(line), want or None, line)
            found += bool(want)
        self.assertGreater(found, 3)

    def test_a_kernel_message_goes_as_before(self):
        lines = capture_lines("openbsd", "dmesg")
        lines += ['em0 at pci0 dev 2 function 0 "Intel" rev 0x01', "em0 at pci0 dev 2 function 0 Intel rev 0x01",
                  'em0 at pci0 dev 2 function 0 "Intel rev 0x01', "e at pci0 dev 2 function 0 x rev",
                  "em0 at a1b2 dev 2 function 0 x rev", "em0 at pci", "vio0 at virtio0: address",
                  "em0 at pci0 dev 2 function 0 nothing"]
        found = [0, 0]
        for line in lines:
            m = OLD_DMESG_PCI.match(line)
            want = m and (m.group(1), m.group(2) or (m.group(3) or "").strip())
            self.assertEqual(H.dmesg_pci_name(line), want or None, line)
            found[0] += bool(want)
            m = OLD_DMESG_AT.match(line)
            want = m and (m.group(1), m.group(2), m.group(3) or (m.group(4) or "").strip())
            self.assertEqual(H.dmesg_attach(line), want or None, line)
            found[1] += bool(want)
        self.assertGreater(min(found), 3)


if __name__ == "__main__":
    unittest.main()

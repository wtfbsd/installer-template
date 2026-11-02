# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The illumos adapter: its parsers (lib/illumos.py), the disk and hardware
# probes (lib/diskprobe.py, lib/hwprobe.py) and the disk plan
# (lib/diskplan.py), on the outputs of OpenIndiana 2026.10
# (tests/fixtures/captures/illumos, hw-captures/illumos, fixtures/illumos).

import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import diskplan as D  # noqa: E402
import diskprobe as P  # noqa: E402
import hwprobe as H  # noqa: E402
import illumos as L  # noqa: E402

FIX = ROOT / "tests" / "fixtures"
CAPS = FIX / "captures" / "illumos" / "live-host"


def text(*parts):
    return (FIX.joinpath(*parts)).read_text(encoding="utf-8")

DISKINFO = ("SATA\tc1t0d0\tATA\tExample SSD 860\t500107862016\tno\tyes\n"
            "USB\tc2t0d0\tExample\tFlash 64GB\t64000000000\tyes\tno\n"
            "CD\tc3t0d0\tExample\tDVD-RW\t0\tyes\tno\n"
            "NVME\tc4t0024D2E1F3A50001d0\tExample\tNVMe 980\t1000204886016\tno\tyes\n"
            "garbage line\n")


class ParsersTest(unittest.TestCase):
    def test_disks(self):
        self.assertEqual(L.disks(DISKINFO), [
            ("c1t0d0", "ATA Example SSD 860", 500107862016),
            ("c2t0d0", "Example Flash 64GB", 64000000000),
            ("c4t0024D2E1F3A50001d0", "Example NVMe 980", 1000204886016)])

    def test_links(self):
        self.assertEqual(L.links("e1000g0\nvioif0\n\nbad name\nixgbe1\n"),
                         ["e1000g0", "vioif0", "ixgbe1"])

    def test_layouts(self):
        self.assertEqual(L.layouts("US-English=33\nGerman=9\n# comment\nbad\n"),
                         ["US-English", "German"])

    def test_hash(self):
        self.assertEqual(L.hash_scheme("CRYPT_DEFAULT=5\n"), "sha512")


class DiskNamesTest(unittest.TestCase):
    """cXtYdZ is a disk on illumos; a slice, a path or a line break is not."""

    def test_names(self):
        for name in ("c2t0d0", "c4t0d0", "c0t5000CCA012345678d0", "c1d0", "ada0", "nda12"):
            with self.subTest(name):
                self.assertTrue(D.DISK_RE.fullmatch(name))
                self.assertTrue(P.DISK_NAME_RE.fullmatch(name))
        for name in ("c2t0d0s1", "c2t0d0p0", "../c2t0d0", "c2t0d0\nx", "C2t0d0", "c2t0xd0", "c"):
            with self.subTest(name):
                self.assertFalse(D.DISK_RE.fullmatch(name))
                self.assertFalse(P.DISK_NAME_RE.fullmatch(name))


class CapturedTest(unittest.TestCase):
    """The disk and hardware probes on the captured outputs."""

    def test_the_disks(self):
        runner = P.Replay(str(CAPS), {"c4t0d0": {"signature": "", "empty": True}})
        disks = {d["name"]: d for d in P.probe("illumos", ["c2t0d0", "c4t0d0"], runner)["disks"]}
        root = disks["c2t0d0"]
        self.assertEqual((root["model"], root["serial"], root["size_bytes"], root["bus"], root["ssd"]),
                         ("Virtio Block Device", "BHYVE-0000-0000-0001", 171798691840, "VirtIO", False))
        self.assertEqual(root["os"], [{"name": "ZFS", "detail": "ZFS pool rpool"}])
        self.assertEqual(root["free"], [])
        empty = disks["c4t0d0"]
        self.assertEqual((empty["serial"], empty["size_bytes"]), ("BHYVE-0000-0000-0002", 21474836480))
        self.assertEqual(empty["os"], [])
        self.assertEqual(empty["free"], [{"start_mb": 1, "size_mb": 20479}])

    def test_the_parsers(self):
        info = P.illumos_diskinfo(text("captures", "illumos", "live-host", "diskinfo_-Hp.out"))
        self.assertEqual(sorted(info), ["c2t0d0", "c4t0d0"])
        self.assertEqual(P.illumos_pools(text("captures", "illumos", "live-host", "zpool_status.out")),
                         {"c2t0d0": "rpool"})
        self.assertEqual(P.illumos_pools(""), {})

    def test_the_hardware(self):
        report = H.probe("illumos", H.Replay(str(FIX / "hw-captures" / "illumos")))
        found = sorted((d["class"], d["driver"], d["name"], d["status"]) for d in report["devices"])
        self.assertEqual(found, [
            ("Ethernet", "vioif", "Red Hat, Inc. Virtio network device", "working"),
            ("GPU", "vgatext", "display (vgatext)", "basic display (no DRM driver)"),
            ("Input", "kb8042", "keyboard (kb8042)", "working"),
            ("Input", "mouse8042", "mouse (mouse8042)", "working")])
        self.assertEqual(report["unavailable"], [])

    def test_the_hash_scheme_of_the_captured_policy(self):
        self.assertEqual(L.hash_scheme(text("illumos", "policy.conf")), "sha512")
        self.assertIn("6\tcrypt_sha512.so.1", text("illumos", "crypt.conf"))
        self.assertEqual(L.hash_scheme("CRYPT_DEFAULT=2b\n"), "bcrypt")
        self.assertEqual(L.hash_scheme("CRYPT_DEFAULT=__unix__\n"), "sha512")

    def test_the_keymaps_of_the_captured_layouts(self):
        names = L.layouts(text("illumos", "kbd_layouts"))
        self.assertIn("US-English", names)
        self.assertIn("German", names)


class LiveDiskTest(unittest.TestCase):
    """The disks the live system needs are never offered."""

    def test_the_medium_and_the_pool_of_the_root(self):
        status = text("captures", "illumos", "live-host", "zpool_status.out")
        self.assertEqual(L.excluded(text("illumos", "mnttab-live"), status), ["c1t0d0"])
        self.assertEqual(L.excluded(text("illumos", "mnttab-installed"), status), ["c2t0d0"])
        self.assertEqual(L.excluded("", status), [])
        usb = "/dev/dsk/c3t0d0p1:1\t/.cdrom\tpcfs\tro\t1\n"
        self.assertEqual(L.excluded(usb, ""), ["c3t0d0"])


class LiveDiskRefusalTest(unittest.TestCase):
    """When the disks of the running system cannot be told, nothing is
    offered: the probe refuses (fail closed), it never excludes nothing."""

    def status(self):
        return text("captures", "illumos", "live-host", "zpool_status.out")

    def test_a_zfs_root_with_zpool_status_failing_is_refused(self):
        mnttab = text("illumos", "mnttab-installed")
        with self.assertRaises(L.Unknown):
            L.excluded_checked(mnttab, "", 1)

    def test_a_zfs_root_whose_pool_has_no_readable_member_is_refused(self):
        no_members = "  pool: rpool\n state: ONLINE\nconfig:\n\n\tNAME STATE\n\trpool ONLINE\n" \
                     "\t  /dev/lofi/1 ONLINE\n"
        mnttab = text("illumos", "mnttab-installed")
        other = self.status().replace("rpool", "tank")
        with self.assertRaises(L.Unknown):
            L.excluded_checked(mnttab, no_members, 0)
        with self.assertRaises(L.Unknown):
            L.excluded_checked(mnttab, other, 0)

    def test_a_live_system_without_its_medium_is_refused(self):
        live = text("illumos", "mnttab-live")
        no_medium = "\n".join(l for l in live.split("\n") if "/.cdrom" not in l)
        with self.assertRaises(L.Unknown):
            L.excluded_checked(no_medium, "", 1)
        odd = live.replace("/dev/dsk/c1t0d0s2", "/devices/odd")
        with self.assertRaises(L.Unknown):
            L.excluded_checked(odd, "", 1)

    def test_no_root_in_mnttab_is_refused(self):
        with self.assertRaises(L.Unknown):
            L.excluded_checked("", "", 1)

    def test_what_can_be_told_is_told(self):
        self.assertEqual(L.excluded_checked(text("illumos", "mnttab-installed"), self.status(), 0),
                         ["c2t0d0"])
        self.assertEqual(L.excluded_checked(text("illumos", "mnttab-live"), "", 1), ["c1t0d0"])


class WifiTest(unittest.TestCase):
    """dladm scan-wifi -p -o essid,secmode,strength (documented format)."""

    def test_scan(self):
        out = L.wifi("Example Home:wpa:very good\nExample\\:Shop:none:weak\n"
                     "Old:wep:good\nbad line\nBar|Pipe:wpa:good\n")
        self.assertEqual(out, [("Example Home", "wpa2", 75), ("Example:Shop", "open", 30),
                               ("Old", "wep", 55)])


class CapabilitiesTest(unittest.TestCase):
    """What the illumos install command takes is what the page offers."""

    def caps(self):
        return json.loads(text("illumos", "capabilities.json"))

    def test_the_built_in_table_agrees_with_the_install_command(self):
        caps = self.caps()
        table = D.system("illumos")
        given = D.system("illumos", {"disks": [], "capabilities": caps})
        for key in ("layouts", "filesystems", "modes", "data_pools", "boot", "encryption",
                    "home_encryption", "swap_encryption", "usages", "not_offered"):
            with self.subTest(key):
                self.assertEqual(table[key] if not isinstance(table[key], tuple) else tuple(table[key]),
                                 given[key])

    def test_usages(self):
        two = {"disks": [{"name": "c2t0d0"}, {"name": "c4t0d0"}]}
        self.assertEqual(D.system("illumos")["usages"], ("together",))
        self.assertEqual(D.system("freebsd")["usages"], ("together", "separate"))
        self.assertFalse(D.needs_usage_question(two, "illumos"))
        self.assertTrue(D.needs_usage_question(two, "freebsd"))
        both = dict(two, capabilities={"usages": ["together", "separate", "sideways"]})
        self.assertTrue(D.needs_usage_question(both, "illumos"))

    def plan(self, **kw):
        plan = {"version": 1, "mode": "erase", "disks": ["c4t0d0"], "layout": "single",
                "filesystem": "zfs"}
        plan.update(kw)
        return plan

    def report(self):
        return {"disks": [{"name": "c4t0d0", "size_bytes": 64 * 2 ** 30},
                          {"name": "c5t0d0", "size_bytes": 64 * 2 ** 30}],
                "capabilities": self.caps()}

    def test_a_plan_on_illumos_disks(self):
        self.assertEqual(D.validate(self.plan(), self.report(), "illumos"), [])

    def test_separately_is_refused_where_it_is_not_offered(self):
        plan = self.plan(usage="separate", data=[])
        self.assertIn("using the disks separately is not offered on illumos: choose another way to use them",
                      D.validate(plan, self.report(), "illumos"))

    def test_swap_encryption(self):
        self.assertFalse(D.system("illumos")["swap_encryption"])
        self.assertTrue(D.system("freebsd")["swap_encryption"])
        self.assertFalse(D.system("freebsd", {"disks": [], "capabilities": {
            "swap_encryption": False}})["swap_encryption"])
        self.assertTrue(D.system("freebsd", {"disks": [], "capabilities": {
            "swap_encryption": "no"}})["swap_encryption"])
        plan = self.plan(swap_mb=2048, encryption={"enabled": True, "swap": True})
        self.assertIn("encrypting the swap is not offered on illumos: turn swap encryption off",
                      D.validate(plan, self.report(), "illumos"))
        bsd = {"disks": [{"name": "ada0", "size_bytes": 64 * 2 ** 30}]}
        self.assertEqual(D.validate(dict(plan, disks=["ada0"], filesystem="zfs"), bsd, "freebsd"), [])

    def test_home_encryption_takes_the_encryption_of_the_plan(self):
        plan = self.plan(encryption={"enabled": True, "swap": False})
        self.assertEqual(D.validate(plan, self.report(), "illumos"), [])
        none = dict(self.report(), capabilities=dict(self.caps(), home_encryption=""))
        self.assertTrue(any("not offered on illumos" in e for e in D.validate(plan, none, "illumos")))


if __name__ == "__main__":
    unittest.main()

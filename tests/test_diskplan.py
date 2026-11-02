# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit, property and fuzz tests of the disk plan (lib/diskplan.py): the
# rules the root helper runs as root on a file a user wrote.

import copy
import json
import pathlib
import random
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import diskplan as D  # noqa: E402
import hashes  # noqa: E402
import netplan  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures" / "disks"


def detail(name):
    return json.loads((FIXTURES / f"{name}.json").read_text())


def good(mode="erase"):
    if mode == "erase":
        return {"version": 1, "mode": "erase", "boot": "uefi", "disks": ["ada0", "ada1"],
                "layout": "mirror", "filesystem": "zfs",
                "encryption": {"enabled": True, "swap": True}, "swap_mb": 8192,
                "sector_4k": True, "trim": True, "wipe": {"ada0": "quick"},
                "confirm_foreign": [], "data": [{"name": "data", "disks": ["ada2"],
                "layout": "single", "filesystem": "zfs", "mount": "/data"}]}
    if mode == "alongside":
        free = detail("dual-os")["disks"][0]["free"][0]
        return {"version": 1, "mode": "alongside", "boot": "uefi", "disks": [],
                "filesystem": "zfs", "swap_mb": 0,
                "alongside": {"disk": "nda0", "region": {"start_mb": free["start_mb"],
                                                          "size_mb": 200 * 1024}}}
    return {"version": 1, "mode": "manual", "boot": "uefi", "disks": [], "filesystem": "zfs",
            "partitions": [{"disk": "nda0", "type": "efi", "size_mb": 260, "mount": "/boot/efi"},
                           {"disk": "nda0", "type": "root", "size_mb": 0, "mount": "/"}]}


class RulesTest(unittest.TestCase):
    def test_good_plans_pass(self):
        self.assertEqual(D.validate(good("erase"), detail("three-disks"), "freebsd"), [])
        self.assertEqual(D.validate(good("alongside"), detail("dual-os"), "freebsd"), [])
        self.assertEqual(D.validate(good("manual"), detail("one-disk"), "freebsd"), [])

    def cases(self):
        three = detail("three-disks")
        yield "an unknown key", dict(good(), evil=1), three
        yield "version 2", dict(good(), version=2), three
        yield "a disk that is not offered", dict(good(), disks=["ada0", "ada9"]), three
        yield "a path for a disk", dict(good(), disks=["/dev/ada0", "ada1"]), three
        yield "a disk twice", dict(good(), disks=["ada0", "ada0"]), three
        yield "a system disk as a data disk", dict(good(), disks=["ada0", "ada2"]), three
        yield "mirror on one disk", dict(good(), disks=["ada0"], data=[]), three
        yield "raidz3 on three disks", dict(good(), disks=["ada0", "ada1", "ada2"], layout="raidz3",
                                            data=[]), three
        yield "a layout of another system", dict(good(), layout="raid5"), three
        yield "UFS on two disks", dict(good(), filesystem="ufs"), three
        yield "encrypted swap without swap", dict(good(), swap_mb=0), three
        yield "swap as a boolean", dict(good(), swap_mb=True), three
        yield "swap too large", dict(good(), swap_mb=1 << 30), three
        yield "a wipe that is not one", dict(good(), wipe={"ada0": "shred"}), three
        yield "a wipe of something else", dict(good(), wipe={"../x": "quick"}), three
        yield "boot by floppy", dict(good(), boot="floppy"), three
        yield "a data pool on /", dict(good(), data=[dict(good()["data"][0], mount="/")]), three
        yield "a data pool with .. in its path", dict(
            good(), data=[dict(good()["data"][0], mount="/data/../etc")]), three
        dual = detail("dual-os")
        erase_dual = {"version": 1, "mode": "erase", "disks": ["nda0"], "layout": "single",
                      "filesystem": "zfs"}
        yield "erasing Windows without the confirmation", erase_dual, dual
        alongside = good("alongside")
        alongside["alongside"]["region"]["size_mb"] = 10 ** 7
        yield "a region larger than the free space", alongside, dual
        bad_region = good("alongside")
        bad_region["alongside"]["region"] = {"start_mb": True, "size_mb": 1}
        yield "a region of booleans", bad_region, dual
        one = detail("one-disk")
        manual = good("manual")
        manual["partitions"] = manual["partitions"][:1]
        yield "manual without a root", manual, one
        manual = good("manual")
        manual["partitions"][0]["type"] = "data"
        yield "UEFI without an EFI partition", manual, one
        manual = good("manual")
        manual["partitions"][0]["size_mb"] = 10 ** 9
        yield "partitions larger than the disk", manual, one
        manual = good("manual")
        manual["partitions"].append({"disk": "nda0", "type": "data", "size_mb": 1, "mount": "/"})
        yield "a mount point twice", manual, one
        manual = good("manual")
        manual["partitions"][1]["mount"] = "/home"
        yield "the root not on /", manual, one
        manual = good("manual")
        manual["disks"] = ["raidz3"]
        yield "manual with system disks (found by the fuzz)", manual, one
        yield "partitions in Erase and install (found by the fuzz)", dict(good(), partitions="x"), three
        yield "alongside in Erase and install", dict(good(), alongside={"disk": "ada0"}), three
        manual = good("manual")
        manual["partitions"].append({"disk": "nda0", "type": "data", "size_mb": 1, "mount": "/srv/./x"})
        yield "a mount point with a dot", manual, one

    def test_every_broken_plan_is_refused(self):
        for name, plan, report in self.cases():
            with self.subTest(name):
                self.assertNotEqual(D.validate(plan, report, "freebsd"), [], name)

    def test_the_confirmation_allows_erasing_another_system(self):
        dual = detail("dual-os")
        plan = {"version": 1, "mode": "erase", "disks": ["nda0"], "layout": "single",
                "filesystem": "zfs", "confirm_foreign": ["nda0"]}
        self.assertEqual(D.validate(plan, dual, "freebsd"), [])

    def test_a_disk_too_small_for_the_system_is_refused(self):
        # The captured disks are 1 to 4 GiB: the plan must not pass.
        small = {"disks": [{"name": "vtbd4", "size_bytes": 2 * 1024 ** 3, "partitions": [],
                            "os": [], "free": []}]}
        plan = {"version": 1, "mode": "erase", "disks": ["vtbd4"], "layout": "single",
                "filesystem": "zfs"}
        errors = D.validate(plan, small, "freebsd")
        self.assertTrue(any("smaller than" in e for e in errors), errors)
        small["disks"][0]["size_bytes"] = 16 * 1024 ** 3
        self.assertEqual(D.validate(plan, small, "freebsd"), [])

    def small_disk(self, gb, requirements=None):
        detail = {"disks": [{"name": "vtbd4", "size_bytes": gb * 1024 ** 3, "partitions": [],
                             "os": [], "free": []}]}
        if requirements is not None:
            detail["requirements"] = requirements
        return detail

    def test_the_minimum_is_a_setting(self):
        plan = {"version": 1, "mode": "erase", "disks": ["vtbd4"], "layout": "single",
                "filesystem": "zfs"}
        # MIN_DISK_GB=8 and a small image: an 8 GB disk is enough.
        self.assertEqual(D.validate(plan, self.small_disk(8, {"min_disk_gb": 8, "image_bytes": 3 * 1024 ** 3}),
                                    "freebsd"), [])
        errors = D.validate(plan, self.small_disk(7, {"min_disk_gb": 8, "image_bytes": 3 * 1024 ** 3}),
                            "freebsd")
        self.assertTrue(any("8 GB" in e and "MIN_DISK_GB" in e for e in errors), errors)

    def test_never_below_what_the_media_needs(self):
        # The image takes 10 GB: 10 + 2 to spare + 4 of swap = 16 GB, above
        # the setting of 8.
        plan = {"version": 1, "mode": "erase", "disks": ["vtbd4"], "layout": "single",
                "filesystem": "zfs", "swap_mb": 4096}
        req = {"min_disk_gb": 8, "image_bytes": 10 * 1024 ** 3}
        self.assertEqual(D.min_disk_mb(req, 4096), 16 * 1024)
        errors = D.validate(plan, self.small_disk(15, req), "freebsd")
        self.assertTrue(any("16 GB" in e and "image" in e and "swap" in e for e in errors), errors)
        self.assertEqual(D.validate(plan, self.small_disk(16, req), "freebsd"), [])

    def test_the_default_is_16_gb(self):
        self.assertEqual(D.min_disk_mb({}, 0), 16 * 1024)

    def test_every_disk_named_is_one_the_plan_uses(self):
        # A wipe or a confirmation of a disk the plan does not erase (here
        # ada1: the running system, not offered; da0: offered, untouched)
        # is refused, so -p never names a disk outside the plan.
        dual = detail("dual-os")
        base = {"version": 1, "mode": "erase", "disks": ["nda0"], "layout": "single",
                "filesystem": "zfs", "confirm_foreign": ["nda0"]}
        self.assertEqual(D.validate(base, dual, "freebsd"), [])
        for extra in ({"wipe": {"ada1": "secure"}}, {"wipe": {"da0": "quick"}},
                      {"confirm_foreign": ["nda0", "ada1"]}, {"confirm_foreign": ["nda0", "da0"]}):
            with self.subTest(extra):
                errors = D.validate(dict(base, **extra), dual, "freebsd")
                self.assertTrue(any("not one the plan erases" in e for e in errors), errors)
        free = dual["disks"][0]["free"][0]
        along = {"version": 1, "mode": "alongside", "disks": [], "filesystem": "zfs",
                 "alongside": {"disk": "nda0", "region": {"start_mb": free["start_mb"], "size_mb": 102400}},
                 "wipe": {"nda0": "quick"}}
        self.assertTrue(any("not one the plan erases" in e for e in D.validate(along, dual, "freebsd")))

    def test_the_minimum_holds_for_alongside_and_manual(self):
        dual = detail("dual-os")
        dual["requirements"] = {"min_disk_gb": 16, "image_bytes": 10 * 1024 ** 3}
        free = dual["disks"][0]["free"][0]
        along = {"version": 1, "mode": "alongside", "disks": [], "filesystem": "zfs",
                 "alongside": {"disk": "nda0", "region": {"start_mb": free["start_mb"], "size_mb": 8192}}}
        errors = D.validate(along, dual, "freebsd")
        self.assertTrue(any("smaller than" in e for e in errors), errors)
        along["alongside"]["region"]["size_mb"] = 20480
        self.assertEqual(D.validate(along, dual, "freebsd"), [])
        manual = {"version": 1, "mode": "manual", "disks": [], "filesystem": "zfs",
                  "confirm_foreign": ["da0"],
                  "partitions": [{"disk": "da0", "type": "efi", "size_mb": 260, "mount": "/boot/efi"},
                                 {"disk": "da0", "type": "root", "size_mb": 8192, "mount": "/"}]}
        errors = D.validate(manual, dual, "freebsd")
        self.assertTrue(any("smaller than" in e for e in errors), errors)
        manual["partitions"][1]["size_mb"] = 0     # the rest of the 64 GB disk
        self.assertEqual(D.validate(manual, dual, "freebsd"), [])

    def test_an_encrypted_layout_needs_encryption(self):
        dual = detail("dual-os")
        plan = {"version": 1, "mode": "erase", "disks": ["nda0"], "layout": "crypto",
                "filesystem": "ffs", "confirm_foreign": ["nda0"]}
        errors = D.validate(plan, dual, "openbsd")
        self.assertTrue(any("encrypt" in e for e in errors), errors)
        plan["encryption"] = {"enabled": True, "swap": False}
        self.assertEqual(D.validate(plan, dual, "openbsd"), [])

    def test_layouts_follow_the_system(self):
        three = detail("three-disks")
        plan = dict(good(), layout="raid5", disks=["ada0", "ada1", "ada2"], data=[],
                    filesystem="ffs")
        self.assertEqual(D.validate(dict(plan, filesystem="ffs-wapbl"), three, "netbsd"), [])
        self.assertNotEqual(D.validate(plan, three, "openbsd"), [])  # no RAID 5 on OpenBSD
        self.assertNotEqual(D.validate(dict(plan, layout="raidz1"), three, "openbsd"), [])
        self.assertNotEqual(D.validate(dict(plan, layout="mirror", filesystem="hammer2",
                                            disks=["ada0", "ada1"]), three, "dragonfly"), [])


class SizesTest(unittest.TestCase):
    def test_usable_and_redundancy(self):
        tb = 2 * 10 ** 12
        cards = {c["ident"]: c for c in D.layout_cards("freebsd", [tb, tb, tb])}
        self.assertEqual(cards["raidz1"]["usable_bytes"], 2 * tb)
        self.assertEqual(cards["mirror"]["usable_bytes"], tb)
        self.assertEqual(cards["stripe"]["usable_bytes"], 3 * tb)
        self.assertEqual(cards["raidz1"]["redundancy"], "survives 1 disk failure")
        self.assertEqual(cards["mirror"]["redundancy"], "survives 2 disk failures")
        self.assertIn("at least 4", cards["raidz2"]["reason"])
        self.assertIn("even", D.layout("freebsd", "raid10").fits(5))
        self.assertEqual(D.default_layout("freebsd", 2), "mirror")
        self.assertEqual(D.default_layout("netbsd", 3), "raid5")

    def test_swap_and_strength(self):
        self.assertEqual(D.default_swap_mb(2048), 2048)
        self.assertEqual(D.default_swap_mb(65536), 16384)
        self.assertEqual(D.passphrase_strength("")[0], 0)
        self.assertLess(D.passphrase_strength("abc")[0], 2)
        self.assertEqual(D.passphrase_strength("Correct-Horse-Battery-9")[1], "strong")


class InstallTypesTest(unittest.TestCase):
    """The page "Installation type": what every type does, whether it can be
    chosen, and what the machine holds."""

    def types(self, name):
        return {t["ident"]: t for t in D.install_types(detail(name), "ExampleBSD")}

    def test_a_fresh_disk(self):
        types = self.types("one-disk")
        self.assertEqual(list(types), ["erase", "alongside", "manual"])
        self.assertTrue(types["erase"]["available"])
        self.assertEqual(types["erase"]["warning"], "")
        self.assertTrue(types["manual"]["available"])
        # An empty disk is all free space: there is room alongside nothing,
        # but nothing to keep; it is offered all the same.
        self.assertTrue(types["alongside"]["available"])

    def test_a_disk_with_two_systems_and_room(self):
        types = self.types("dual-os")
        self.assertTrue(types["alongside"]["available"])
        self.assertIn("nda0 holds Windows 11 and Debian 13", types["erase"]["warning"])

    def test_a_disk_with_two_systems_and_no_room(self):
        types = self.types("dual-os-full")
        self.assertFalse(types["alongside"]["available"])
        self.assertIn("16 GB", types["alongside"]["reason"])
        self.assertIn("Windows 11", types["erase"]["warning"])

    def test_the_machine_summary(self):
        lines = D.machine_summary(detail("dual-os"))
        self.assertIn("nda0 (Example NVMe 980 1TB, 1.0 TB) holds Windows 11 and Debian 13; "
                      "239 GB free", lines)
        self.assertTrue(any(line.startswith("da0 (") and line.endswith("is empty")
                            for line in lines), lines)


class BlankTest(unittest.TestCase):
    """A blank disk: no partition table, no filesystem, pool or encryption
    signature, nothing unknown."""

    def test_blank_and_not(self):
        blank = {"name": "ada0", "scheme": "none", "partitions": [], "os": []}
        self.assertTrue(D.is_blank(blank))
        for name, extra in (("a partition table", {"scheme": "GPT"}),
                            ("partitions", {"partitions": [{"kind": "efi"}]}),
                            ("another system", {"os": [{"name": "Linux"}]}),
                            ("a whole-disk signature", {"signature": "ZFS pool data"}),
                            ("something unknown", {"unknown_bytes": 4096})):
            with self.subTest(name):
                self.assertFalse(D.is_blank(dict(blank, **extra)))

    def test_the_notice_is_for_exactly_one_blank_disk(self):
        self.assertTrue(D.single_blank(detail("one-disk")))
        self.assertFalse(D.single_blank(detail("three-disks")))  # three blank disks: a real choice
        self.assertFalse(D.single_blank(detail("dual-os")))
        self.assertFalse(D.single_blank({"disks": []}))


class UsageTest(unittest.TestCase):
    """Two or more disks: together (one pool or array) or separately (one
    system disk, every other disk its own drive)."""

    def test_the_question_is_for_two_disks_or_more(self):
        self.assertTrue(D.needs_usage_question(detail("three-disks")))
        self.assertTrue(D.needs_usage_question(detail("dual-os")))
        self.assertFalse(D.needs_usage_question(detail("one-disk")))

    def test_a_separate_plan(self):
        plan = D.separate_plan("ada0", {"ada1": "/home", "ada2": None}, "zfs")
        self.assertEqual(plan["usage"], "separate")
        self.assertEqual(plan["disks"], ["ada0"])
        self.assertEqual(plan["layout"], "single")
        self.assertEqual(plan["data"], [{"name": "home", "disks": ["ada1"], "layout": "single",
                                         "filesystem": "zfs", "mount": "/home"}])
        full = dict(plan, version=1, mode="erase", filesystem="zfs")
        self.assertEqual(D.validate(full, detail("three-disks"), "freebsd"), [])

    def test_separate_means_one_system_disk_and_single_drives(self):
        three = detail("three-disks")
        base = {"version": 1, "mode": "erase", "filesystem": "zfs", "usage": "separate"}
        self.assertNotEqual(D.validate(dict(base, disks=["ada0", "ada1"], layout="mirror"),
                                       three, "freebsd"), [])
        self.assertNotEqual(D.validate(dict(base, disks=["ada0"], layout="single", data=[
            {"name": "data", "disks": ["ada1", "ada2"], "layout": "mirror", "filesystem": "zfs",
             "mount": "/data"}]), three, "freebsd"), [])
        self.assertNotEqual(D.validate(dict(base, usage="sideways", disks=["ada0"], layout="single"),
                                       three, "freebsd"), [])
        # Together with a separate data disk: allowed (mixed).
        mixed = {"version": 1, "mode": "erase", "filesystem": "zfs", "usage": "together",
                 "disks": ["ada0", "ada1"], "layout": "mirror",
                 "data": [{"name": "data", "disks": ["ada2"], "layout": "single",
                           "filesystem": "zfs", "mount": "/data"}]}
        self.assertEqual(D.validate(mixed, three, "freebsd"), [])

    def test_the_summary_says_which(self):
        plan = dict(D.separate_plan("ada0", {"ada1": "/home"}, "zfs"), version=1, mode="erase",
                    filesystem="zfs")
        text = " ".join(t for _n, t, _d in D.actions(plan, detail("three-disks"), "freebsd", "X"))
        self.assertIn("used separately", text)
        mixed = {"version": 1, "mode": "erase", "filesystem": "zfs", "usage": "together",
                 "disks": ["ada0", "ada1"], "layout": "mirror"}
        text = " ".join(t for _n, t, _d in D.actions(mixed, detail("three-disks"), "freebsd", "X"))
        self.assertIn("used together", text)


class CapabilitiesTest(unittest.TestCase):
    """What the install command of the system can do is what the adapter
    says (the "capabilities" of the disk report); nothing else is offered
    or accepted."""

    OPENBSD = {"modes": ["erase"], "data_pools": False,
               "layouts": [{"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1},
                           {"ident": "raid1", "title": "RAID 1 (softraid)", "min_disks": 2},
                           {"ident": "crypto", "title": "Encrypted (softraid CRYPTO)",
                            "min_disks": 1, "max_disks": 1, "encrypted": True},
                           {"ident": "raid1c", "title": "RAID 1C (mirrored and encrypted)",
                            "min_disks": 2, "encrypted": True}],
               "filesystems": [["ffs", "FFS"]], "encryption": "softraid CRYPTO",
               "not_offered": "not offered on OpenBSD yet"}

    def report(self, name="three-disks"):
        return dict(detail(name), capabilities=self.OPENBSD)

    def test_raid5_is_never_offered_on_openbsd(self):
        three = self.report()
        idents = [c["ident"] for c in D.layout_cards("openbsd", [10 ** 12] * 3, three)]
        self.assertEqual(idents, ["single", "raid1", "crypto", "raid1c"])
        plan = {"version": 1, "mode": "erase", "disks": ["ada0", "ada1", "ada2"],
                "layout": "raid5", "filesystem": "ffs"}
        self.assertNotEqual(D.validate(plan, three, "openbsd"), [])
        self.assertEqual(D.validate(dict(plan, layout="raid1"), three, "openbsd"), [])

    def test_the_built_in_openbsd_table_offers_no_raid5_either(self):
        self.assertNotIn("raid5", [l.ident for l in D.layouts("openbsd")])

    def test_modes_and_data_pools_the_command_refuses_are_greyed_and_refused(self):
        dual = dict(detail("dual-os"), capabilities=self.OPENBSD)
        types = {t["ident"]: t for t in D.install_types(dual, "X", "openbsd")}
        self.assertFalse(types["alongside"]["available"])
        self.assertIn("not offered on OpenBSD yet", types["alongside"]["reason"])
        self.assertFalse(types["manual"]["available"])
        self.assertTrue(types["erase"]["available"])
        plan = {"version": 1, "mode": "erase", "disks": ["ada0", "ada1"], "layout": "raid1",
                "filesystem": "ffs", "data": [{"name": "data", "disks": ["ada2"],
                "layout": "single", "filesystem": "ffs", "mount": "/data"}]}
        errors = D.validate(plan, self.report(), "openbsd")
        self.assertTrue(any("data pools" in e for e in errors), errors)
        self.assertFalse(D.data_pools_offered("openbsd", self.report()))

    def test_the_boot_modes_are_those_of_the_install_command(self):
        def boot(value):
            caps = dict(self.OPENBSD, boot=value)
            return D.system("dragonfly", dict(detail("three-disks"), capabilities=caps))["boot"]
        self.assertEqual(boot(["uefi"]), ("uefi",))
        self.assertEqual(boot(["uefi", "floppy"]), ("uefi",))
        self.assertEqual(boot(["floppy"]), ("uefi", "bios"))
        self.assertEqual(boot([]), ("uefi", "bios"))
        self.assertEqual(boot("uefi"), ("uefi", "bios"))
        uefi = dict(detail("three-disks"), capabilities=dict(self.OPENBSD, boot=["uefi"]))
        plan = {"version": 1, "mode": "erase", "disks": ["ada0"], "layout": "single",
                "filesystem": "ffs", "boot": "bios"}
        self.assertTrue(any("boot mode" in e for e in D.validate(plan, uefi, "openbsd")))

    def test_the_answer_of_capabilities_is_checked(self):
        good = json.dumps(dict(self.OPENBSD, boot=["uefi"], other=1))
        self.assertEqual(D.check_capabilities(good)["boot"], ["uefi"])
        self.assertNotIn("other", D.check_capabilities(good))
        for bad in ("not JSON", "[]", '{"boot": ["uefi"]}', '{"layouts": [{"title": "x"}]}',
                    json.dumps(dict(self.OPENBSD, pad="x" * 70000))):
            with self.subTest(bad[:30]):
                self.assertIsNone(D.check_capabilities(bad))

    def test_as_root_only_a_command_of_root_runs(self):
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            cmd = os.path.join(tmp, "x-install")
            with open(cmd, "w", encoding="utf-8") as stream:
                stream.write("#!/bin/sh\nexit 0\n")
            os.chmod(cmd, 0o755)  # nosec B103 - a stub that must be executable, in a private temp dir
            self.assertTrue(D.trusted_command(cmd))
            if os.geteuid() != 0:
                with mock.patch("os.geteuid", return_value=0):
                    self.assertFalse(D.trusted_command(cmd))
            os.chmod(cmd, 0o644)
            self.assertFalse(D.trusted_command(cmd))

    def test_no_encryption_in_the_capabilities_refuses_an_encrypted_plan(self):
        caps = {"encryption": "", "filesystems": [["ffs", "FFSv2"], ["lfs", "LFS"]],
                "layouts": [{"ident": "single", "title": "Single disk", "min_disks": 1, "max_disks": 1}]}
        report = dict(detail("three-disks"), capabilities=caps)
        plan = {"version": 1, "mode": "erase", "disks": ["ada0"], "layout": "single",
                "filesystem": "lfs", "encryption": {"enabled": True, "swap": False}}
        self.assertIn("encrypting the system is not offered on NetBSD: turn encryption off",
                      D.validate(plan, report, "netbsd"))
        self.assertEqual(D.validate(dict(plan, encryption={"enabled": False, "swap": False}),
                                    report, "netbsd"), [])
        self.assertEqual(D.system("netbsd", report)["encryption"], "")
        self.assertEqual(D.system("netbsd")["encryption"], "cgd")
        disk = D.disk_index(report)["ada0"]
        labels = [s["label"] for s in D.bar_after(disk, plan, "netbsd", "X", report)]
        self.assertIn("X (LFS)", labels)

    def test_without_capabilities_the_built_in_table_is_used(self):
        self.assertTrue(D.data_pools_offered("freebsd", detail("three-disks")))


class ParseTest(unittest.TestCase):
    def test_a_plan_file_is_read_strictly(self):
        self.assertEqual(D.parse(json.dumps(good()).encode())["mode"], "erase")
        for name, data in (
                ("duplicate key", b'{"version":1,"version":2}'),
                ("NaN", b'{"swap_mb":NaN}'),
                ("Infinity", b'{"swap_mb":Infinity}'),
                ("a fraction", b'{"swap_mb":1.5}'),
                ("an exponent", b'{"swap_mb":1e400}'),
                ("a list", b"[]"),
                ("a string", b'"plan"'),
                ("not UTF-8", b'{"mode":"\xff"}'),
                ("too large", b'{"x":"' + b"a" * 70000 + b'"}'),
                ("nested deeply", b'{"a":' * 20 + b"1" + b"}" * 20),
                ("brackets bomb", b"[" * 100000),
                ("a long list", json.dumps({"disks": ["ada0"] * 300}).encode()),
                ("a long text", json.dumps({"mode": "e" * 300}).encode()),
                ("huge integer", b'{"swap_mb":' + b"9" * 5000 + b"}"),
                ("not JSON", b"mode=erase")):
            with self.subTest(name):
                with self.assertRaises(D.PlanError):
                    D.parse(data)


class FuzzTest(unittest.TestCase):
    """Random plans, mutated: validate never raises, never accepts a plan
    with a disk the report does not offer, and accepts a mutation only when
    every rule still holds."""

    VALUES = [None, True, False, 0, -1, 1, 2 ** 31, 2 ** 63, "", "ada0", "nda0", "ada9",
              "/dev/ada0", "../etc", "/", "/data", "zfs", "ufs", "mirror", "raidz3",
              "erase", "manual", "alongside", [], {}, ["ada0"], {"ada0": "quick"},
              [{"disk": "ada0"}], {"enabled": True}, "x" * 300]

    def mutate(self, rng, value, depth=0):
        if depth > 4 or rng.random() < 0.25:
            return copy.deepcopy(rng.choice(self.VALUES))
        if isinstance(value, dict):
            out = dict(value)
            action = rng.random()
            if out and action < 0.4:
                key = rng.choice(sorted(out))
                out[key] = self.mutate(rng, out[key], depth + 1)
            elif out and action < 0.6:
                del out[rng.choice(sorted(out))]
            else:
                out[rng.choice(sorted(D.PLAN_KEYS) + ["evil", "disk", "mount"])] = \
                    self.mutate(rng, None, depth + 1)
            return out
        if isinstance(value, list):
            out = list(value)
            if out and rng.random() < 0.5:
                i = rng.randrange(len(out))
                out[i] = self.mutate(rng, out[i], depth + 1)
            else:
                out.append(self.mutate(rng, None, depth + 1))
            return out
        return copy.deepcopy(rng.choice(self.VALUES))

    def test_mutated_plans(self):
        rng = random.Random(1675)
        reports = {name: detail(name) for name in ("one-disk", "three-disks", "dual-os")}
        seeds = [good("erase"), good("alongside"), good("manual")]
        accepted = 0
        for _ in range(4000):
            plan = self.mutate(rng, rng.choice(seeds))
            report = reports[rng.choice(sorted(reports))]
            for os_name in ("freebsd", "netbsd", "openbsd", "dragonfly"):
                errors = D.validate(plan, report, os_name)
                self.assertIsInstance(errors, list)
                if errors:
                    continue
                accepted += 1
                offered = set(D.disk_index(report))
                named = list(plan.get("disks") or []) + \
                    sorted({p["disk"] for p in plan.get("partitions") or []}) + \
                    [n for pool in plan.get("data") or [] for n in pool["disks"]]
                if plan.get("mode") == "alongside":
                    named.append(plan["alongside"]["disk"])
                self.assertLessEqual(set(named), offered, plan)
                self.assertEqual(len(named), len(set(named)), plan)
                self.assertLessEqual(set(plan), D.PLAN_KEYS, plan)
                self.assertEqual(plan["version"], 1)
        self.assertGreater(accepted, 0, "the fuzz never produced a plan that passes")

    def test_random_bytes_never_crash_the_parser(self):
        rng = random.Random(1676)
        base = json.dumps(good()).encode()
        for _ in range(3000):
            data = bytearray(base)
            for _ in range(rng.randrange(1, 8)):
                i = rng.randrange(len(data))
                data[i] = rng.randrange(256)
            try:
                plan = D.parse(bytes(data))
            except D.PlanError:
                continue
            self.assertIsInstance(D.validate(plan, detail("three-disks"), "freebsd"), list)


class AsciiDigitsTest(unittest.TestCase):
    """The patterns of the root helper's checks take 0 to 9 only: in Python
    3 \\d matches every digit of Unicode, and int() reads them."""

    ARABIC_THREE = "\u0663"  # ٣

    def test_a_disk_name_with_another_digit_is_refused(self):
        self.assertTrue(D.DISK_RE.fullmatch("ada3"))
        self.assertIsNone(D.DISK_RE.fullmatch("ada" + self.ARABIC_THREE))
        plan = dict(good(), disks=["ada" + self.ARABIC_THREE, "ada1"])
        errors = D.validate(plan, detail("three-disks"), "freebsd")
        self.assertIn(f"disks: 'ada{self.ARABIC_THREE}' is not the name of a disk", errors)

    def test_a_crypt_hash_with_another_digit_is_refused(self):
        three = self.ARABIC_THREE
        sha = "$6$rounds=5000$saltsalt$" + "a" * 86
        bcrypt = "$2b$12$" + "a" * 53
        self.assertTrue(hashes.HASH_PATTERNS["sha512"].fullmatch(sha))
        self.assertTrue(hashes.HASH_PATTERNS["bcrypt"].fullmatch(bcrypt))
        self.assertTrue(hashes.HASH_PATTERNS["bcrypt-2a"].fullmatch(bcrypt.replace("2b", "2a", 1)))
        cases = (("sha512", sha.replace("5000", "500" + three)),
                 ("bcrypt", bcrypt.replace("12", "1" + three, 1)),
                 ("bcrypt-2a", bcrypt.replace("2b", "2a", 1).replace("12", "1" + three, 1)))
        for scheme, bad in cases:
            with self.subTest(scheme=scheme):
                self.assertIsNone(hashes.HASH_PATTERNS[scheme].fullmatch(bad))

    def test_an_ipv6_prefix_with_another_digit_is_refused(self):
        self.assertEqual(netplan.check_ipv6("em0:2001:db8::10/64:"), [])
        self.assertNotEqual(netplan.check_ipv6("em0:2001:db8::10/6" + self.ARABIC_THREE + ":"), [])


if __name__ == "__main__":
    unittest.main()


class AdapterTableAgreeTest(unittest.TestCase):
    """The built-in table (diskplan.SYSTEMS) is the fallback for the
    capabilities an adapter's os_layouts reports; the two must say the
    same, or a disk report without capabilities offers something the
    install command does not take."""

    FIELDS = ("modes", "data_pools", "encryption", "not_offered", "filesystems")

    @staticmethod
    def adapter_caps(os_name):
        text = (ROOT / "adapters" / f"{os_name}.sh").read_text()
        start = text.find("os_layouts() {")
        if start < 0:
            return None
        body = text[text.index("<<'JSON'\n", start) + len("<<'JSON'\n"):]
        return json.loads(body[:body.index("\nJSON\n")])

    def test_every_adapter_with_layouts_matches_the_table(self):
        checked = 0
        for os_name in sorted(D.SYSTEMS):
            caps = self.adapter_caps(os_name)
            if caps is None:
                continue
            checked += 1
            table = D.system(os_name)
            reported = D.system(os_name, {"capabilities": caps})
            with self.subTest(os=os_name):
                self.assertEqual(
                    [(x.ident, x.min_disks, x.max_disks, x.encrypted) for x in table["layouts"]],
                    [(x.ident, x.min_disks, x.max_disks, x.encrypted) for x in reported["layouts"]])
                for key in self.FIELDS:
                    self.assertEqual(table[key], reported[key], key)
        self.assertGreater(checked, 0)

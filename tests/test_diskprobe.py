# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the disk detection (lib/diskprobe.py): the outputs of the
# real tools, captured on FreeBSD 16, NetBSD 11, OpenBSD 8.0 and DragonFly
# 6.4.2 with ten disk layouts (tests/fixtures/captures, anonymised), are
# replayed and the report must say what is on each disk.
#
# The signature read (the first MiB and the last sector of a disk or a
# partition) has no capture: the replay is told what it finds, from what
# the disks were made with (the README of the captures), and the read
# itself is tested on bytes laid out as the formats define them.

import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import diskplan as D  # noqa: E402
import diskprobe as P  # noqa: E402

CAPTURES = ROOT / "tests" / "fixtures" / "captures"
PREFIX = {"freebsd": "vtbd", "netbsd": "ld", "openbsd": "sd", "dragonfly": "vbd"}
UNIT = {"01": [1], "02": [2], "04": [3], "05": [1], "06": [2], "07": [3], "08": [4],
        "09": [5], "10": [4, 5, 6, 7]}
LAYOUTS = {"01": "01-blank", "02": "02-windows-linux-gpt", "04": "04-mbr-ntfs-ext4",
           "05": "05-zfs-whole-disk", "06": "06-geli-zfs-freebsd-install",
           "07": "07-freebsd-ufs-old-install", "08": "08-linux-luks2",
           "09": "09-random-first-mib", "10": "10-softraid-raidframe"}
SYSTEMS = ("freebsd", "netbsd", "openbsd", "dragonfly")


# FreeBSD has follow-up captures of these layouts: geli dump, zdb -l and
# the first 4 KiB of the devices; nothing is told to the replay there.
FOLLOW_UP = {"05", "06", "08", "09"}


def sniffs(os_name, layout):
    """What the signature read finds on the disks of a layout."""
    if os_name == "freebsd" and layout in FOLLOW_UP:
        return {}
    disk = f"{PREFIX[os_name]}{UNIT[layout][0]}"
    return {
        "01": {disk: {"signature": "", "empty": True}},
        "05": {disk: {"signature": "zfs", "empty": False}},
        # The GELI provider: the freebsd-zfs partition at sector 1585152.
        "06": {f"{disk}:1585152": {"signature": "geli", "empty": False}},
        # The LUKS2 partition at sector 1574912.
        "08": {f"{disk}:1574912": {"signature": "luks", "empty": False}},
        "09": {disk: {"signature": "", "empty": False}},
    }.get(layout, {})


def report(os_name, layout):
    names = [f"{PREFIX[os_name]}{n}" for n in UNIT[layout]]
    runner = P.Replay(str(CAPTURES / os_name / LAYOUTS[layout]), sniffs(os_name, layout))
    return {d["name"]: d for d in P.probe(os_name, names, runner)["disks"]}


def first(os_name, layout):
    return report(os_name, layout)[f"{PREFIX[os_name]}{UNIT[layout][0]}"]


def systems(disk):
    return [(o["name"], o["detail"]) for o in disk["os"]]


class EveryLayoutTest(unittest.TestCase):
    def test_a_blank_disk_is_blank(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "01")
                self.assertTrue(D.is_blank(disk), disk)
                self.assertEqual(disk["size_bytes"], 1024 * P.MiB)
                self.assertEqual(disk["free"], [{"start_mb": 1, "size_mb": 1023}])

    def test_random_data_is_never_called_empty(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "09")
                self.assertFalse(D.is_blank(disk))
                self.assertEqual(systems(disk), [("Unknown data", "data the installer cannot read")])
                # Erasing it needs the typed confirmation.
                self.assertTrue(D.foreign(disk))

    def test_a_disk_that_cannot_be_read_is_not_empty(self):
        runner = P.Replay(str(CAPTURES / "freebsd" / LAYOUTS["01"]))
        disk = P.probe("freebsd", ["vtbd1"], runner)["disks"][0]
        self.assertFalse(D.is_blank(disk))

    def test_windows_and_linux_on_gpt(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "02")
                self.assertEqual(disk["scheme"], "GPT")
                self.assertEqual(disk["size_bytes"], 4 * 1024 * P.MiB)
                self.assertEqual(systems(disk), [("Windows", "Windows"), ("Linux", "Debian")])
                self.assertEqual([p["kind"] for p in disk["partitions"]],
                                 ["efi", "msr", "windows", "recovery", "linux", "swap"])
                self.assertEqual([p["size_bytes"] // P.MiB for p in disk["partitions"]],
                                 [100, 16, 1800, 600, 1000, 256])
                # The 323M at the end, less the backup GPT.
                self.assertEqual(disk["free"], [{"start_mb": 3773, "size_mb": 322}])

    def test_openbsd_calls_ntfs_msdos_and_is_not_believed(self):
        disk = first("openbsd", "02")
        windows = disk["partitions"][2]
        self.assertEqual((windows["kind"], windows["fs"]), ("windows", ""))
        self.assertNotIn("FAT", windows["label"])

    def test_mbr_ntfs_and_ext4(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "04")
                self.assertEqual(disk["scheme"], "MBR")
                self.assertEqual([p["kind"] for p in disk["partitions"]], ["windows", "linux"])
                self.assertEqual([n for n, _d in systems(disk)], ["Windows", "Linux"])
                self.assertEqual(disk["free"], [{"start_mb": 2901, "size_mb": 170}])

    def test_whole_disk_zfs(self):
        # FreeBSD names the pool (zpool import); fstyp does not know it.
        self.assertEqual(systems(first("freebsd", "05")), [("ZFS", "ZFS pool tank")])
        for os_name in ("netbsd", "openbsd", "dragonfly"):
            with self.subTest(os_name):
                disk = first(os_name, "05")
                self.assertEqual(systems(disk), [("ZFS", "a ZFS pool")])
                self.assertFalse(D.is_blank(disk))
                self.assertEqual(disk["free"], [])

    def test_zfs_without_the_signature_read_on_freebsd(self):
        runner = P.Replay(str(CAPTURES / "freebsd" / LAYOUTS["05"]))
        disk = P.probe("freebsd", ["vtbd1"], runner)["disks"][0]
        self.assertEqual(systems(disk), [("ZFS", "ZFS pool tank")])

    def test_geli_encrypted_freebsd(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "06")
                self.assertEqual(systems(disk), [("FreeBSD", "FreeBSD (encrypted with GELI)")])
                self.assertEqual([p["kind"] for p in disk["partitions"]],
                                 ["efi", "bsd", "swap", "encrypted"])

    def test_old_freebsd_ufs(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "07")
                self.assertEqual(systems(disk), [("FreeBSD", "FreeBSD")])
                self.assertEqual([p["type"] for p in disk["partitions"]],
                                 ["freebsd-boot", "freebsd-ufs", "freebsd-swap"])

    def test_luks_encrypted_linux(self):
        for os_name in SYSTEMS:
            with self.subTest(os_name):
                disk = first(os_name, "08")
                self.assertEqual(systems(disk), [("Linux", "Debian (encrypted with LUKS)")])
                self.assertEqual([p["kind"] for p in disk["partitions"]], ["efi", "linux", "encrypted"])

    def test_netbsd_assembles_raidframe(self):
        disks = report("netbsd", "10")
        self.assertEqual(disks["ld6"]["member_of"], "raid0 (RAIDframe RAID 1)")
        self.assertEqual(disks["ld7"]["member_of"], "raid0 (RAIDframe RAID 1)")
        self.assertEqual(systems(disks["ld6"]), [("RAID", "a member of raid0 (RAIDframe RAID 1)")])
        self.assertEqual(disks["raid0"]["assembled"]["members"], ["ld6", "ld7"])
        # The softraid chunks are just OpenBSD partitions to NetBSD.
        self.assertEqual(systems(disks["ld4"]), [("OpenBSD", "OpenBSD")])

    def test_openbsd_assembles_softraid(self):
        disks = report("openbsd", "10")
        self.assertEqual(disks["sd4"]["member_of"], "sd8 (softraid RAID1)")
        self.assertEqual(disks["sd5"]["member_of"], "sd8 (softraid RAID1)")
        self.assertEqual(disks["sd8"]["assembled"]["members"], ["sd4", "sd5"])
        self.assertIn("NetBSD RAIDframe member", [d for _n, d in systems(disks["sd6"])])

    def test_other_systems_see_raid_members_by_their_type(self):
        for os_name in ("freebsd", "dragonfly"):
            with self.subTest(os_name):
                disks = report(os_name, "10")
                pre = PREFIX[os_name]
                self.assertEqual(systems(disks[f"{pre}6"]), [("NetBSD", "NetBSD RAIDframe member")])
                self.assertEqual(systems(disks[f"{pre}4"]), [("OpenBSD", "OpenBSD")])
                self.assertNotIn("assembled", disks[f"{pre}4"])

    def test_netbsd_wedges_are_matched_by_their_start_not_their_number(self):
        text = (CAPTURES / "netbsd" / LAYOUTS["02"] / "dkctl_listwedges_ld2.out").read_text()
        # The same wedges numbered as after another boot.
        renumbered = text.replace("dk2:", "dk21:").replace("dk5:", "dk2:").replace("dk7:", "dk5:")
        wedges = P.netbsd_wedges(renumbered)
        self.assertEqual([(w, s) for w, _n, s, _t in wedges][:3],
                         [("dk21", 2048), ("dk4", 206848), ("dk2", 239616)])

    def test_the_esp_names_are_matched_in_any_case(self):
        self.assertEqual(P.efi_systems(["EFI/Microsoft/Boot/BOOTMGFW.EFI", "EFI/DEBIAN/GRUBX64.EFI"]),
                         [("Windows", "Windows"), ("Linux", "Debian")])

    def test_the_report_passes_the_section(self):
        for os_name in SYSTEMS:
            for layout in LAYOUTS:
                with self.subTest(os_name=os_name, layout=layout):
                    for disk in report(os_name, layout).values():
                        for p in disk["partitions"]:
                            self.assertIn(p["kind"], {"efi", "msr", "windows", "recovery", "linux",
                                                      "swap", "data", "bsd", "encrypted", "raid",
                                                      "other"})
                            self.assertGreaterEqual(p["size_bytes"], 0)


class FollowUpTest(unittest.TestCase):
    """FreeBSD, from the tools alone: geli dump, zdb -l, the first 4 KiB."""

    def test_geli_from_geli_dump(self):
        runner = P.Replay(str(CAPTURES / "freebsd" / LAYOUTS["06"]))
        disk = P.probe("freebsd", ["vtbd2"], runner)["disks"][0]
        self.assertIn("geli_dump_vtbd2p4", runner.keys)
        self.assertEqual(systems(disk), [("FreeBSD", "FreeBSD (encrypted with GELI)")])

    def test_the_pool_on_the_raw_disk_from_zdb(self):
        # Without zpool import (an imported or a foreign pool): zdb -l.
        directory = CAPTURES / "freebsd" / LAYOUTS["05"]

        class NoImport(P.Replay):
            def run(self, key, argv):
                return (1, "") if key == "zpool_import" else super().run(key, argv)

        runner = NoImport(str(directory))
        disk = P.probe("freebsd", ["vtbd1"], runner)["disks"][0]
        self.assertIn("zdb_-l_vtbd1", runner.keys)
        self.assertEqual(systems(disk), [("ZFS", "ZFS pool tank")])

    def test_luks_from_its_first_bytes_under_the_name_of_the_other_boot(self):
        directory = str(CAPTURES / "freebsd" / LAYOUTS["08"])
        self.assertEqual(P.Replay(directory).alias(directory), ("vtbd4", "vtbd3"))
        head = P.parse_od((CAPTURES / "freebsd" / LAYOUTS["08"] / "dd_first4k_od_vtbd3p3.out").read_text())
        self.assertEqual(head[:8], bytes.fromhex("4c554b53babe0002"))
        disk = P.probe("freebsd", ["vtbd4"], P.Replay(directory))["disks"][0]
        self.assertEqual(systems(disk), [("Linux", "Debian (encrypted with LUKS)")])

    def test_the_follow_up_disk_is_the_same_disk(self):
        # The GPT header in the first 4 KiB (LBA 1) names the last usable
        # sector, which gpart list of the first boot names too.
        layout = CAPTURES / "freebsd" / LAYOUTS["08"]
        head = P.parse_od((layout / "dd_first4k_od_vtbd3.out").read_text())
        self.assertEqual(head[512:520], b"EFI PART")
        last = int.from_bytes(head[512 + 48:512 + 56], "little")
        self.assertIn(f"last: {last}", (layout / "gpart_list_vtbd4.out").read_text())

    def test_random_data_from_its_first_bytes(self):
        directory = str(CAPTURES / "freebsd" / LAYOUTS["09"])
        disk = P.probe("freebsd", ["vtbd5"], P.Replay(directory))["disks"][0]
        self.assertEqual(systems(disk), [("Unknown data", "data the installer cannot read")])

    def test_od_repeats(self):
        text = "0000000    00  01\n0000002    00  00\n*\n0000008    ff\n0000009\n"
        self.assertEqual(P.parse_od(text), b"\x00\x01\x00\x00\x00\x00\x00\x00\xff")


class SignatureTest(unittest.TestCase):
    def test_luks(self):
        self.assertEqual(P.sniff_bytes(b"LUKS\xba\xbe\x00\x02" + b"\0" * 4096, b"")["signature"], "luks")

    def test_bitlocker(self):
        head = b"\xeb\x58\x90-FVE-FS-" + b"\0" * 4096
        self.assertEqual(P.sniff_bytes(head, b"")["signature"], "bitlocker")

    def test_geli_in_the_last_sector(self):
        self.assertEqual(P.sniff_bytes(b"\x01" * 4096, b"GEOM::ELI" + b"\0" * 503)["signature"], "geli")

    def test_zfs_uberblock(self):
        head = bytearray(P.MiB)
        off = 128 * 1024 + 5 * 1024
        head[off:off + 8] = (0x00bab10c).to_bytes(8, "little")
        self.assertEqual(P.sniff_bytes(bytes(head), b"")["signature"], "zfs")

    def test_zeros_and_data(self):
        self.assertEqual(P.sniff_bytes(b"\0" * P.MiB, b"\0" * 512), {"signature": "", "empty": True})
        self.assertFalse(P.sniff_bytes(b"\0" * 1000 + b"\x07" + b"\0" * 100, b"")["empty"])


class CommandsTest(unittest.TestCase):
    def test_only_reading_tools_are_run(self):
        for os_name in SYSTEMS:
            for layout in LAYOUTS:
                names = [f"{PREFIX[os_name]}{n}" for n in UNIT[layout]]
                runner = P.Replay(str(CAPTURES / os_name / LAYOUTS[layout]))
                P.probe(os_name, names, runner)
                for key in runner.keys:
                    self.assertRegex(key, r"^(sysctl_-n_|diskinfo_-v_|gpart_list_|fstyp_|zpool_import$|"
                                          r"gpt_show_|dkctl_listwedges_|fdisk_|raidctl_-s_|"
                                          r"disklabel_-h_|bioctl_|geli_dump_|zdb_-l_)", key)

    def test_the_tools_have_absolute_paths(self):
        for name, paths in P.TOOLS.items():
            for path in paths:
                self.assertTrue(path.startswith("/"), (name, path))


# The patterns the line parsers replaced (they backtrack super-linearly);
# a parser gives what its pattern gave, on every line of every capture.
OLD_NOTE = re.compile(r"\s*\(.*\)$")
OLD_GPT_SHOW = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d*)\s*(.*)$")
OLD_WEDGE = re.compile(r"^(dk\d+): (.*), (\d+) blocks at (\d+), type: ?(.*)$")
OLD_FDISK_GPT = re.compile(r"^\s*(\d+): (.+?)\s*\[\s*(\d+):\s*(\d+) \]")
OLD_DRAGONFLY = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")


def capture_lines(os_name, prefix):
    """Every line of the captures of a tool, with the lines of the edge
    cases the captures do not have."""
    for path in sorted((CAPTURES / os_name).rglob(prefix + "*.out")):
        yield from path.read_text(encoding="utf-8", errors="replace").split("\n")


class LineParserTest(unittest.TestCase):
    def test_the_note_of_a_diskinfo_key_goes_as_before(self):
        keys = [raw.split("#", 1)[1].strip() for raw in capture_lines("freebsd", "diskinfo_-v_")
                if "#" in raw]
        keys += ["mediasize in bytes (1.0G)", "a (b) (c)", "x(", "x)", "(y)", "a \t(b", "a (b)c",
                 "a\u2003(b)", ")(", "a ((b)"]
        self.assertIn("mediasize in bytes", [P.without_note(k) for k in keys])
        for key in keys:
            self.assertEqual(P.without_note(key), OLD_NOTE.sub("", key), key)

    def test_a_row_of_gpt_show_goes_as_before(self):
        lines = list(capture_lines("netbsd", "gpt_show_-a_"))
        lines += ["  34  2014  ", "1 2 3", "1 2", " 1\t2\u2003 7x GPT part", "1 2 \u0663 MBR part 7",
                  " " * 20 + "1 2 3 GPT part", "1 2 3GPT part"]
        found = 0
        for raw in lines:
            m = OLD_GPT_SHOW.match(raw)
            want = None if not m or raw.startswith(" " * 20) else \
                (int(m.group(1)), int(m.group(2)), m.group(3), m.group(4).strip())
            self.assertEqual(P.gpt_show_row(raw), want, raw)
            found += want is not None
        self.assertGreater(found, 10)

    def test_a_wedge_goes_as_before(self):
        lines = [raw.strip() for raw in capture_lines("netbsd", "dkctl_listwedges_")]
        lines += ["dk1: a, 5 blocks at 6, type: ffs, 7 blocks at 8, type: x",
                  "dk1: , 5 blocks at 6, type:", "dk1: a, 5 blocks at 6, type:ffs",
                  "dk1: a, 5 blocks at x, type: ffs", "dk: a, 5 blocks at 6, type: ffs",
                  "dk1: a, 5 blocks at 6, type:  , 1 blocks at 2, type: y"]
        found = 0
        for line in lines:
            m = OLD_WEDGE.match(line)
            want = m and (m.group(1), m.group(2), int(m.group(4)), m.group(5).strip())
            self.assertEqual(P.netbsd_wedge(line), want or None, line)
            found += bool(want)
        self.assertGreater(found, 5)

    def test_a_gpt_row_of_openbsd_fdisk_goes_as_before(self):
        lines = list(capture_lines("openbsd", "fdisk_"))
        lines += ["1: [ 1: 2 ] x [ 3: 4 ]", "1:  [ 1: 2 ]", "1: a  [x: 2 ] [ 5:6 ]", "1: a[ 1: 2 ]",
                  "1: \t\t[ 1: 2 ]", " 0: EFI Sys    [       64:   2048 ]", "1: a [ 1: 2]"]
        found = 0
        for raw in lines:
            m = OLD_FDISK_GPT.match(raw)
            want = m and (m.group(2), int(m.group(3)), int(m.group(4)))
            self.assertEqual(P.openbsd_fdisk_gpt_row(raw), want or None, raw)
            found += bool(want)
        self.assertGreater(found, 5)

    def test_a_row_of_dragonfly_gpt_show_goes_as_before(self):
        lines = list(capture_lines("dragonfly", "gpt_show_"))
        lines += ["1 2 3 ", "1 2 3", "1 2 3  GPT part - x  ", "1 2 - MBR part 7"]
        found = 0
        for raw in lines:
            old = OLD_DRAGONFLY.match(raw)
            new = P.DRAGONFLY_ROW_RE.match(raw)
            self.assertEqual(new is None, old is None, raw)
            if old:
                self.assertEqual(new.groups(), old.groups()[:3], raw)
                self.assertEqual(raw[new.end():].strip(), old.group(4).strip(), raw)
                found += 1
        self.assertGreater(found, 5)

    def test_a_disk_name_is_ascii(self):
        for name in ("vtbd1", "sd12", "ada0", "vtbd\u0663", "Ad0", "a", "1", "ld1a"):
            self.assertEqual(bool(P.DISK_NAME_RE.fullmatch(name)),
                             bool(re.fullmatch(r"[a-z]+[0-9]+", name)), name)


if __name__ == "__main__":
    unittest.main()

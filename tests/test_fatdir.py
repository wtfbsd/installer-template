# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the userland FAT reader (lib/fatdir.py) the disk probe uses
# instead of mounting an EFI system partition.
#
# The file systems are made by mkfs.fat (or newfs_msdos) when it is
# installed; the tree of an EFI system partition is then written into them
# by a small writer below (8.3 entries, long names, the FAT chains), so the
# boot sector and the FAT layout are the real tool's.  The boot sectors of
# the real EFI system partitions of the captures are read too, and broken
# file systems must give nothing or part, never an exception or a hang.

import os
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import diskprobe as P  # noqa: E402
import fatdir as F  # noqa: E402

CAPTURES = ROOT / "tests" / "fixtures" / "captures"
MKFS = shutil.which("mkfs.fat") or shutil.which("mkfs.vfat") or shutil.which("newfs_msdos")

TREE = ["EFI/", "EFI/Boot/", "EFI/Boot/bootx64.efi", "EFI/Microsoft/", "EFI/Microsoft/Boot/",
        "EFI/Microsoft/Boot/bootmgfw.efi", "EFI/Microsoft/Boot/BCD", "EFI/debian/",
        "EFI/debian/grubx64.efi", "EFI/debian/shimx64.efi"]


def make_fs(fat_bits, size_mb):
    """A FAT file system made by the system's tool, as bytes."""
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "esp.img")
    with open(path, "wb") as stream:
        stream.truncate(size_mb * 1024 * 1024)
    if MKFS.endswith("newfs_msdos"):
        cmd = [MKFS, "-F", str(fat_bits), "-c", "1", "-C", "0", path]
    else:
        cmd = [MKFS, "-F", str(fat_bits), "-s", "1", path]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(path, "rb") as stream:
        data = bytearray(stream.read())
    shutil.rmtree(tmp)
    return data


class Writer:
    """Writes directories and empty files into a FAT image."""

    def __init__(self, image):
        self.img = image
        self.fs = F.Fat(lambda o, n: bytes(self.img[o:o + n]), len(image))
        self.fats = self.img[16]
        self.fat_size = (self.fs.root_start - self.fs.fat_start) // self.fats
        self.next_free = 3 if self.fs.kind == 32 else 2

    def set_fat(self, cluster, value):
        for copy in range(self.fats):
            base = self.fs.fat_start + copy * self.fat_size
            if self.fs.kind == 32:
                self.img[base + cluster * 4:base + cluster * 4 + 4] = value.to_bytes(4, "little")
            elif self.fs.kind == 16:
                self.img[base + cluster * 2:base + cluster * 2 + 2] = (value & 0xFFFF).to_bytes(2, "little")
            else:
                off = base + cluster + cluster // 2
                cur = int.from_bytes(self.img[off:off + 2], "little")
                value &= 0xFFF
                cur = (cur & 0x000F) | (value << 4) if cluster & 1 else (cur & 0xF000) | value
                self.img[off:off + 2] = cur.to_bytes(2, "little")

    def alloc(self):
        cluster = self.next_free
        self.next_free += 1
        self.set_fat(cluster, 0x0FFFFFFF)
        start = self.fs.data_start + (cluster - 2) * self.fs.cluster_bytes
        self.img[start:start + self.fs.cluster_bytes] = bytes(self.fs.cluster_bytes)
        return cluster

    def dir_area(self, cluster):
        if cluster == 0:
            return self.fs.root_start
        return self.fs.data_start + (cluster - 2) * self.fs.cluster_bytes

    @staticmethod
    def short_name(name, index):
        base, _dot, ext = name.partition(".")
        plain = base.upper()[:8] == base and ext.upper()[:3] == ext and len(base) <= 8 and len(ext) <= 3
        if plain:
            return (base.ljust(8) + ext.ljust(3)).encode(), False
        stem = "".join(c for c in base.upper() if c.isalnum())[:6] + f"~{index}"
        return (stem.ljust(8) + ext.upper()[:3].ljust(3)).encode(), True

    def add(self, parent, name, is_dir, slot):
        """Writes the entries of name in the directory parent from slot."""
        short, needs_lfn = self.short_name(name, slot + 1)
        area = self.dir_area(parent)
        entries = []
        if needs_lfn:
            check = 0
            for b in short:
                check = (((check & 1) << 7) + (check >> 1) + b) & 0xFF
            units = name.encode("utf-16-le") + b"\x00\x00"
            units += b"\xff\xff" * ((-len(units) // 2) % 13)
            parts = [units[i:i + 26] for i in range(0, len(units), 26)]
            for seq in range(len(parts), 0, -1):
                p = parts[seq - 1]
                e = bytearray(32)
                e[0] = seq | (0x40 if seq == len(parts) else 0)
                e[1:11], e[11], e[13] = p[0:10], 0x0F, check
                e[14:26], e[28:32] = p[10:22], p[22:26]
                entries.append(bytes(e))
        cluster = self.alloc() if is_dir else 0
        e = bytearray(32)
        e[0:11] = short
        e[11] = 0x10 if is_dir else 0x20
        e[26:28] = (cluster & 0xFFFF).to_bytes(2, "little")
        e[20:22] = (cluster >> 16).to_bytes(2, "little")
        entries.append(bytes(e))
        for i, entry in enumerate(entries):
            pos = area + (slot + i) * 32
            self.img[pos:pos + 32] = entry
        return cluster, slot + len(entries)

    def tree(self, paths):
        dirs = {"": (self.fs.root_cluster if self.fs.kind == 32 else 0, 0)}
        for path in paths:
            is_dir = path.endswith("/")
            parent, _sep, name = path.rstrip("/").rpartition("/")
            pc, slot = dirs[parent]
            cluster, slot = self.add(pc, name, is_dir, slot)
            dirs[parent] = (pc, slot)
            if is_dir:
                dirs[path.rstrip("/")] = (cluster, 0)


def reader(data):
    return lambda o, n: bytes(data[o:o + n])


@unittest.skipUnless(MKFS, "no mkfs.fat or newfs_msdos to make a FAT file system")
class MadeByTheToolTest(unittest.TestCase):
    def check(self, bits, size_mb):
        image = make_fs(bits, size_mb)
        fs = F.Fat(reader(image), len(image))
        self.assertEqual(fs.kind, bits)
        Writer(image).tree(TREE)
        files = F.list_files(reader(image), len(image))
        self.assertEqual(sorted(files), sorted(p.rstrip("/") for p in TREE))
        self.assertEqual(P.efi_systems(files), [("Windows", "Windows"), ("Linux", "Debian")])
        return image

    def test_fat12_fat16_and_fat32(self):
        for bits, size_mb in ((12, 1), (16, 20), (32, 40)):
            with self.subTest(bits=bits):
                self.check(bits, size_mb)

    def test_broken_file_systems_never_raise_or_hang(self):
        image = self.check(32, 40)
        rng = random.Random(7)
        for _round in range(300):
            broken = bytearray(image)
            for _hit in range(rng.randint(1, 40)):
                pos = rng.choice([rng.randrange(0, 512), rng.randrange(0, 64 * 1024),
                                  rng.randrange(0, len(broken))])
                broken[pos] = rng.randrange(256)
            files = F.list_files(reader(broken), len(broken))
            self.assertTrue(files is None or len(files) <= F.MAX_NAMES)

    def test_a_directory_that_loops_is_read_once(self):
        image = make_fs(16, 20)
        w = Writer(image)
        w.tree(["EFI/", "EFI/Boot/"])
        # EFI/Boot points back at EFI.
        efi = w.dir_area(0)
        efi_cluster = int.from_bytes(image[efi + 26:efi + 28], "little")
        boot_area = w.dir_area(efi_cluster)
        image[boot_area + 26:boot_area + 28] = efi_cluster.to_bytes(2, "little")
        files = F.list_files(reader(image), len(image))
        self.assertLessEqual(len(files), F.MAX_NAMES)
        self.assertIn("EFI/Boot", files)

    def test_the_probe_reads_the_esp_through_the_whole_disk_without_a_mount(self):
        image = make_fs(32, 40)
        Writer(image).tree(TREE)
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        disk = os.path.join(tmp, "disk")
        with open(disk, "wb") as stream:
            stream.write(os.urandom(1024 * 1024) + bytes(image) + os.urandom(4096))

        class Here(P.System):
            def whole_disk(self, name):
                return disk

            def run(self, key, argv):
                raise AssertionError(f"no tool is run to read an ESP: {argv}")

        files = Here("freebsd").esp_files("freebsd", "vtbd9p1", "vtbd9", 1024 * 1024, len(image))
        self.assertEqual(sorted(files), sorted(p.rstrip("/") for p in TREE))

    def test_a_cluster_chain_that_loops_ends(self):
        image = make_fs(16, 20)
        w = Writer(image)
        a, b = w.alloc(), w.alloc()
        w.set_fat(a, b)
        w.set_fat(b, a)                 # a -> b -> a -> ...
        fs = F.Fat(reader(image), len(image))
        self.assertEqual(len(fs.chain(a)), 2 * fs.cluster_bytes)

    def test_a_directory_is_read_up_to_its_cap(self):
        image = make_fs(16, 20)
        w = Writer(image)
        first = w.alloc()
        prev = first
        for _ in range(40):             # a chain of 41 clusters
            nxt = w.alloc()
            w.set_fat(prev, nxt)
            prev = nxt
        fs = F.Fat(reader(image), len(image))
        from unittest import mock
        with mock.patch.object(F, "MAX_DIR_BYTES", 8 * fs.cluster_bytes):
            self.assertEqual(len(fs.chain(first)), 8 * fs.cluster_bytes)
        self.assertEqual(len(fs.chain(first)), 41 * fs.cluster_bytes)

    def test_a_partition_too_small_for_its_file_system_is_refused(self):
        image = make_fs(32, 40)
        self.assertIsNone(F.list_files(reader(image), 1024 * 1024))


class PiecesTest(unittest.TestCase):
    def test_fat12_packs_two_entries_in_three_bytes(self):
        fs = F.Fat.__new__(F.Fat)
        fs.kind, fs._fat = 12, bytes([0xF8, 0xFF, 0xFF, 0x03, 0xF0, 0xFF])
        self.assertEqual(fs.next_cluster(2), 3)
        self.assertEqual(fs.next_cluster(3), -1)

    def test_lower_case_flags_of_a_short_name(self):
        entry = bytearray(32)
        entry[0:11] = b"BOOTX64 EFI"
        entry[11], entry[12] = 0x20, 0x18
        self.assertEqual(list(F.entries(bytes(entry))), [("bootx64.efi", False, 0)])

    @unittest.skipUnless(MKFS, "no mkfs.fat or newfs_msdos")
    def test_nothing_is_read_outside_the_partition(self):
        image = make_fs(16, 20)
        fs = F.Fat(reader(image), len(image))
        with self.assertRaises(F.FatError):
            fs.read(len(image) - 10, 512)


class RealBootSectorsTest(unittest.TestCase):
    def test_the_esps_of_the_captures(self):
        # The first bytes of the EFI system partitions the captured disks
        # hold: made by newfs_msdos (layout 06) and mkfs.vfat (layout 08).
        for layout, dev, size in (("06-geli-zfs-freebsd-install", "vtbd2p1", 260),
                                  ("08-linux-luks2", "vtbd3p1", 256)):
            with self.subTest(layout):
                text = (CAPTURES / "freebsd" / layout / f"dd_first4k_od_{dev}.out").read_text()
                head = P.parse_od(text).ljust(512, b"\0")
                head = head[:510] + b"\x55\xaa" + head[512:]
                fs = F.Fat(reader(head), size * 1024 * 1024)
                self.assertEqual((fs.kind, fs.bps), (32, 512))

    def test_not_fat(self):
        self.assertIsNone(F.list_files(reader(bytes(4096)), 4096))
        self.assertIsNone(F.list_files(reader(os.urandom(4096)), 4096))


if __name__ == "__main__":
    unittest.main()

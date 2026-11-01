# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The parsers of the illumos adapter (lib/illumos.py) on the DOCUMENTED
# formats of the illumos tools.  UNPROVEN: these samples are written from
# the manual pages, not captured; the tests move to captured outputs when
# an illumos machine gives them.

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import illumos as L  # noqa: E402

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


if __name__ == "__main__":
    unittest.main()

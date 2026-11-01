# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The flags of the language picker are image files of the installer
# (gui/flags/<cc>.png and <cc>-2x.png, rendered from flag-icons, MIT), not
# characters a colour emoji font may or may not draw: a live image without
# such a font showed empty boxes.  Every region of the language table has
# its flag, the licence of the set is in THIRD-PARTY, and a region without
# a flag gets its two letters in a badge, never an empty box.

import pathlib
import struct
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import i18n  # noqa: E402

FLAGS = ROOT / "gui" / "flags"


def png_size(path):
    with open(path, "rb") as stream:
        head = stream.read(24)
    assert head[:8] == b"\x89PNG\r\n\x1a\n", path
    return struct.unpack(">II", head[16:24])


class FlagsTest(unittest.TestCase):
    def regions(self):
        return sorted({country for _l, _own, _en, variants in i18n.LANGUAGES
                       for _loc, country, _region in variants})

    def test_every_region_of_the_table_has_a_flag(self):
        for cc in self.regions():
            with self.subTest(cc):
                self.assertEqual(png_size(FLAGS / f"{cc.lower()}.png"), (24, 18))
                self.assertEqual(png_size(FLAGS / f"{cc.lower()}-2x.png"), (48, 36))

    def test_only_the_flags_the_table_uses(self):
        shipped = {p.name.split("-")[0].split(".")[0].upper() for p in FLAGS.glob("*.png")}
        self.assertEqual(shipped, set(self.regions()))

    def test_the_licence_of_the_set_is_noted(self):
        notice = (ROOT / "THIRD-PARTY").read_text(encoding="utf-8")
        self.assertIn("flag-icons", notice)
        self.assertIn("MIT License", notice)
        self.assertIn("Copyright (c) 2013 Panayiotis Lipiridis", notice)
        self.assertIn("gui/flags", notice)

    def test_the_picker_names_the_file_or_a_badge(self):
        self.assertEqual(i18n.flag_file("DE", str(FLAGS), 1), str(FLAGS / "de.png"))
        self.assertEqual(i18n.flag_file("DE", str(FLAGS), 2), str(FLAGS / "de-2x.png"))
        self.assertIsNone(i18n.flag_file("ZZ", str(FLAGS), 1))
        self.assertIsNone(i18n.flag_file("../etc", str(FLAGS), 1))


if __name__ == "__main__":
    unittest.main()

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The identity line in the lower left of the installer: "<Product>
# <version> · <variant> · <arch>" (+ the build date of a test build), from
# /usr/local/share/<slug>/identity (KEY=value, parsed, never sourced), with
# a fallback when the file is not there, and readable (contrast at least
# 4.5:1) on the default palette and on a cyberpunk variant.

import os
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import branding as B  # noqa: E402
import identity as I  # noqa: E402

FIX = ROOT / "tests" / "fixtures"


class IdentityTest(unittest.TestCase):
    def test_the_line(self):
        ident = I.load(str(FIX / "identity"))
        self.assertEqual(I.line(ident, "Fallback", "riscv64", "Linux 7.0"),
                         "ExampleBSD 1.2 · FreeBSD 16.0 · cyberpunk · amd64 · build 2026-11-01")

    def test_a_release_has_no_build_date(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "identity")
        with open(path, "w", encoding="utf-8") as stream:
            stream.write("PRODUCT=ExampleBSD\nVERSION=1.2\nBASE=NetBSD 11.0\nVARIANT=default\n"
                         "ARCH=arm64\n")
        self.assertEqual(I.line(I.load(path), "x", "y", "z"),
                         "ExampleBSD 1.2 · NetBSD 11.0 · default · arm64")

    def test_without_the_file_the_bsd_is_still_named(self):
        self.assertEqual(I.line(I.load("/nonexistent/identity"), "ExampleBSD", "amd64", "OpenBSD 8.0"),
                         "ExampleBSD · OpenBSD 8.0 · amd64")

    def test_the_base_the_installer_detects(self):
        # uname of a BSD names it; on another system (a test machine) the
        # system the installer is configured for.
        self.assertEqual(I.detected_base(("NetBSD", "11.0"), "netbsd"), "NetBSD 11.0")
        self.assertEqual(I.detected_base(("DragonFly", "6.4-RELEASE"), "dragonfly"),
                         "DragonFly 6.4-RELEASE")
        self.assertEqual(I.detected_base(("Linux", "7.0.0-31-generic"), "freebsd"), "FreeBSD")

    def test_parsed_never_sourced(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "identity")
        for bad in ('VERSION=$(id)', 'ARCH=`id`', 'PRODUCT="a"b"', "VARIANT=" + "x" * 100,
                    "EVIL=1", "VERSION=1\x1b[2J"):
            with self.subTest(bad):
                with open(path, "w", encoding="utf-8") as stream:
                    stream.write("PRODUCT=ExampleBSD\n" + bad + "\n")
                ident = I.load(path)
                self.assertEqual(set(ident) - {"PRODUCT"}, set(), ident)

    def test_the_place_of_the_file(self):
        self.assertEqual(I.path_for("examplebsd"), "/usr/local/share/examplebsd/identity")


class ContrastTest(unittest.TestCase):
    def test_contrast_of_known_colours(self):
        self.assertAlmostEqual(B.contrast("000000", "FFFFFF"), 21.0, places=1)
        self.assertAlmostEqual(B.contrast("777777", "FFFFFF"), 4.48, places=1)

    def test_the_line_is_readable_on_both_palettes(self):
        for brand in (B.load(str(FIX / "artwork")),
                      B.load(str(FIX / "artwork"), variant="cyberpunk")):
            with self.subTest(brand.palette.get("TAGLINE")):
                colour = brand.identity_colour()
                for background in (brand.palette["DARK"], brand.palette["DARK2"]):
                    self.assertGreaterEqual(B.contrast(colour, background), 4.5)
                self.assertIn(f"#{colour}", brand.css())

    def test_the_variant_has_its_own_palette(self):
        brand = B.load(str(FIX / "artwork"), variant="cyberpunk")
        self.assertEqual(brand.palette["PRIMARY"], "FF2A6D")
        self.assertEqual(brand.variant, "cyberpunk")
        # Its dim MUTED is not used for the line: it is below 4.5:1.
        self.assertLess(B.contrast(brand.palette["MUTED"], brand.palette["DARK"]), 4.5)
        self.assertNotEqual(brand.identity_colour(), brand.palette["MUTED"])
        # The art of the template is shared when the variant has none.
        self.assertIsNotNone(brand.svg("logo"))

    def test_an_unknown_variant_is_the_default(self):
        brand = B.load(str(FIX / "artwork"), variant="../../etc")
        self.assertEqual(brand.palette["PRIMARY"], "2F6FDE")
        self.assertEqual(brand.variant, "default")


if __name__ == "__main__":
    unittest.main()

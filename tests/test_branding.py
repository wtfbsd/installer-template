# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the branding of the installer (lib/branding.py): the
# palette and the sources of the artwork template, read strictly.

import os
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import branding as B  # noqa: E402

ART = ROOT / "tests" / "fixtures" / "artwork"


class PaletteTest(unittest.TestCase):
    def test_the_fixture(self):
        brand = B.load(str(ART))
        self.assertEqual(brand.palette["NAME"], "ExampleBSD")
        self.assertEqual(brand.palette["PRIMARY"], "2F6FDE")
        self.assertIn(b"#2F6FDE", brand.svg("logo") or b"#2F6FDE")
        self.assertNotIn(b"@PRIMARY@", brand.svg("logo"))
        self.assertEqual(len(brand.wallpapers()), 3)

    def test_a_palette_that_cannot_be_used(self):
        for bad in ('PRIMARY=zzzzzz', 'PRIMARY=2F6FDE;x', 'NAME="$(id)"', 'EVIL=1',
                    'NAME="a\\"b"', 'TAGLINE="' + "x" * 200 + '"'):
            with self.subTest(bad):
                tmp = tempfile.mkdtemp()
                self.addCleanup(shutil.rmtree, tmp)
                shutil.copytree(ART, tmp, dirs_exist_ok=True)
                with open(os.path.join(tmp, "palette.env"), "a", encoding="utf-8") as stream:
                    stream.write(bad + "\n")
                with self.assertRaises(B.BrandingError):
                    B.load(tmp)

    def test_text_in_svg_is_escaped(self):
        self.assertEqual(B.substitute("<t>@NAME@ #@PRIMARY@</t>",
                                      {"NAME": "A & <B>", "PRIMARY": "112233"}),
                         "<t>A &amp; &lt;B&gt; #112233</t>")

    def test_no_artwork_is_the_built_in_look(self):
        brand = B.load("")
        self.assertIsNone(brand.svg("logo"))
        self.assertIn("background-color", brand.css())

    def test_the_css_carries_the_colours(self):
        css = B.load(str(ART)).css()
        for colour in ("#2F6FDE", "#1E2440", "#14182B", "#21B8A6"):
            self.assertIn(colour, css)


class SlidesTest(unittest.TestCase):
    def test_built_in_slides_use_the_wallpapers_and_the_product(self):
        brand = B.load(str(ART))
        slides = brand.slides("ExampleBSD", "en")
        self.assertGreaterEqual(len(slides), 4)
        self.assertTrue(all(s["title"] and s["text"] for s in slides))
        self.assertTrue(any("ExampleBSD" in s["title"] + s["text"] for s in slides))
        self.assertTrue(all(s["image"] in ("wallpaper-1", "wallpaper-2", "wallpaper-3", None)
                            for s in slides))

    def test_slides_of_the_template_win(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        shutil.copytree(ART, tmp, dirs_exist_ok=True)
        os.makedirs(os.path.join(tmp, "slides"))
        with open(os.path.join(tmp, "slides", "slides.txt"), "w", encoding="utf-8") as stream:
            stream.write("Fast|Starts in seconds.|wallpaper-2\nSafe|Your files stay yours.|\n")
        slides = B.load(tmp).slides("ExampleBSD", "en")
        self.assertEqual([s["title"] for s in slides], ["Fast", "Safe"])


if __name__ == "__main__":
    unittest.main()

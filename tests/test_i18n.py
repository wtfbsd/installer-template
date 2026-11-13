# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the languages and strings of the installer (lib/i18n.py).

import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import i18n  # noqa: E402


class LanguagesTest(unittest.TestCase):
    def test_flags_are_regional_indicators(self):
        self.assertEqual(i18n.flag("DE"), "\U0001F1E9\U0001F1EA")

    def test_only_the_locales_the_system_has(self):
        langs = i18n.languages_for(["en_US.UTF-8", "de_CH.UTF-8", "C.UTF-8"])
        self.assertEqual([(l[0], [v[0] for v in l[3]]) for l in langs],
                         [("en", ["en_US.UTF-8"]), ("de", ["de_CH.UTF-8"])])
        self.assertEqual(len(i18n.languages_for([])), len(i18n.LANGUAGES))

    def test_every_locale_has_the_shape_of_the_answer(self):
        for _l, _own, _en, variants in i18n.LANGUAGES:
            for locale, country, _region in variants:
                self.assertRegex(locale, r"^[a-z]{2,3}_[A-Z]{2}\.UTF-8$")
                self.assertTrue(locale.split("_")[1].startswith(country))

    def test_a_locale_suggests_its_layout(self):
        self.assertEqual(i18n.keymap_for("de_CH.UTF-8", ["us", "ch", "de"]), "ch")
        self.assertEqual(i18n.keymap_for("en_GB.UTF-8", ["us", "uk"]), "uk")
        self.assertIsNone(i18n.keymap_for("de_DE.UTF-8", ["us"]))
        # No Swiss layout on offer: the layout of the language.
        self.assertEqual(i18n.keymap_for("de_CH.UTF-8", ["us", "de"]), "de")

    def test_the_exact_layout_wins_over_its_variants(self):
        # The vt keymaps of FreeBSD sort us.acc, us.ctrl ... before us: the
        # layout named exactly is the one suggested, wherever it is listed.
        variants = ["uk.capsctrl", "uk", "us.acc", "us.ctrl", "us.dvorak", "us", "us.unix"]
        self.assertEqual(i18n.keymap_for("en_US.UTF-8", variants), "us")
        self.assertEqual(i18n.keymap_for("en_GB.UTF-8", variants), "uk")
        self.assertEqual(i18n.keymap_for("de_DE.UTF-8", ["de.acc", "de.noacc", "de"]), "de")
        # Only a variant on offer: the first variant, as before.
        self.assertEqual(i18n.keymap_for("de_DE.UTF-8", ["de.acc", "de.noacc"]), "de.acc")


class StringsTest(unittest.TestCase):
    def test_english_is_complete_and_others_fall_back(self):
        self.assertEqual(i18n.t("page.disk", "de"), "Festplatte")
        self.assertEqual(i18n.t("page.disk", "xx"), "Disk")
        self.assertEqual(i18n.missing("en"), [])

    def test_every_shipped_language_is_complete(self):
        for lang in i18n.STRINGS:
            self.assertEqual(i18n.missing(lang), [], lang)

    def test_every_action_of_the_wizard_has_a_label(self):
        import wizard
        for ident in ("next", "back", "try-live", "stop", "close", "install", "stay",
                      "reboot", "retry", "quit"):
            self.assertIn(f"action.{ident}", i18n.STRINGS["en"], ident)
        self.assertTrue(hasattr(wizard, "PAGE_IDS"))

    def test_every_page_has_a_title(self):
        sys.path.insert(0, str(ROOT / "lib"))
        import wizard
        for page in wizard.PAGE_IDS:
            self.assertIn(f"page.{page}", i18n.STRINGS["en"])
            self.assertIn(f"page.{page}", i18n.STRINGS["de"])

    def test_placeholders_match_english(self):
        for lang, table in i18n.STRINGS.items():
            for key, text in table.items():
                want = set(re.findall(r"{(\w+)}", i18n.STRINGS["en"][key]))
                self.assertEqual(set(re.findall(r"{(\w+)}", text)), want, (lang, key))


if __name__ == "__main__":
    unittest.main()

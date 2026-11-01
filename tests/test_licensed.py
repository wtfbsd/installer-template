# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests of the optional licensed software (lib/licensed.py): the
# catalogue, Select all, the accepted items and the acceptance record.

import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import licensed as L  # noqa: E402

CATALOGUE = ROOT / "tests" / "fixtures" / "software" / "licensed-software.json"


class CatalogueTest(unittest.TestCase):
    def test_the_fixture_reads(self):
        cat = L.load(str(CATALOGUE))
        self.assertEqual([i["id"] for i in cat["items"]][:2],
                         ["example-gpu-driver", "example-wifi-firmware"])
        self.assertTrue(L.licence_text(cat, "example-browser-drm").startswith("EXAMPLE CONTENT"))
        self.assertIn("OPEN-SOURCE", L.notices_text(cat))

    def broken(self, mutate):
        tmp = tempfile.mkdtemp()
        try:
            shutil.copytree(CATALOGUE.parent, tmp, dirs_exist_ok=True)
            data = json.loads(CATALOGUE.read_text())
            mutate(data)
            path = os.path.join(tmp, "licensed-software.json")
            pathlib.Path(path).write_text(json.dumps(data))
            with self.assertRaises(L.CatalogueError):
                L.load(path)
        finally:
            shutil.rmtree(tmp)

    def test_a_catalogue_that_cannot_be_used_is_refused(self):
        self.broken(lambda d: d.update(version=2))
        self.broken(lambda d: d["items"][0].update(id="Bad Id"))
        self.broken(lambda d: d["items"].append(dict(d["items"][0])))           # id twice
        self.broken(lambda d: d["items"][0].update(flags=["free-beer"]))
        self.broken(lambda d: d["items"][0]["licence"].update(text="../../etc/passwd"))
        self.broken(lambda d: d["items"][0]["licence"].update(text="/etc/passwd"))
        self.broken(lambda d: d["items"][0]["licence"].update(text="licences/missing.txt"))
        self.broken(lambda d: d["items"][0].update(install={"run": "rm -rf /"}))
        self.broken(lambda d: d["items"][0].update(evil=1))
        self.broken(lambda d: d["items"][0].update(size_bytes=True))


class SelectionTest(unittest.TestCase):
    def setUp(self):
        self.cat = L.load(str(CATALOGUE))

    def test_select_all_skips_non_commercial_and_vendor_key(self):
        ids = L.select_all(self.cat)
        self.assertEqual(ids, ["example-gpu-driver", "example-wifi-firmware", "example-browser-drm"])

    def test_the_three_states(self):
        self.assertEqual(L.select_all_state(self.cat, []), "none")
        self.assertEqual(L.select_all_state(self.cat, ["example-gpu-driver"]), "some")
        self.assertEqual(L.select_all_state(self.cat, L.select_all(self.cat)), "all")
        # The rows Select all leaves alone do not change its state.
        self.assertEqual(L.select_all_state(self.cat, L.select_all(self.cat) + ["example-display-font"]),
                         "all")

    def test_accepted_ids_are_checked(self):
        self.assertEqual(L.check_accepted(self.cat, ["example-gpu-driver"]), [])
        self.assertNotEqual(L.check_accepted(self.cat, ["example-gpu-driver", "nope"]), [])
        self.assertNotEqual(L.check_accepted(self.cat, ["example-gpu-driver"] * 2), [])
        self.assertNotEqual(L.check_accepted(self.cat, ["../x"]), [])

    def test_the_answer_reads_and_writes(self):
        self.assertEqual(L.parse_answer("example-gpu-driver,example-browser-drm"),
                         ["example-gpu-driver", "example-browser-drm"])
        self.assertEqual(L.parse_answer(""), [])
        with self.assertRaises(L.CatalogueError):
            L.parse_answer("example-gpu-driver;rm")

    def test_the_record_of_acceptance(self):
        record = L.record(self.cat, ["example-browser-drm"], "2026-11-01T0930Z")
        self.assertEqual(len(record), 1)
        entry = record[0]
        self.assertEqual(entry["id"], "example-browser-drm")
        self.assertEqual(entry["licence"], "example-drm")
        text = L.licence_text(self.cat, "example-browser-drm").encode()
        self.assertEqual(entry["sha256"], hashlib.sha256(text).hexdigest())
        self.assertEqual(entry["accepted_at"], "2026-11-01T0930Z")


if __name__ == "__main__":
    unittest.main()

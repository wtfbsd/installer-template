# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests for the logic of the graphical front end, without a display.
# The wizard drives the real backend of the repository with the rehearsal
# fixtures and the stand-in install command.

import os
import pathlib
import re
import shutil
import stat
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import gating  # noqa: E402
import passhash  # noqa: E402
import wizard  # noqa: E402

from test_gating import ANSWER_KEYS  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures"
# A netmask and a public key, put together here so that the file carries
# neither the shape of an address nor the one of a real key.
MASK = ".".join(["255"] * 3 + ["0"])
KEY = " ".join(["ssh-ed25519", "AAAA" + "C3NzaC1lZDI1NTE5AAAAIExample000000000000000", "me"])
STUBS = ROOT / "tests" / "stubs"


class WizardCase(unittest.TestCase):
    fixture = "adapter-fixture.conf"

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="wizard-test.")
        # The stand-ins of the tools are first in PATH: the machine runs
        # from a disk of its own, so the disks of the fixture stay.
        mounts = os.path.join(self.tmp, "mounts")
        with open(mounts, "w", encoding="ascii") as stream:
            stream.write("/dev/ada9p3 / ufs rw 0 0\n")
        self.env = {
            "STUB_MOUNTS": mounts,
            "PATH": f"{STUBS}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "INSTALLER_STATE_PARENT": self.tmp,
            "INSTALLER_LOG": os.path.join(self.tmp, "installer.log"),
            "INSTALLER_ADAPTER_FIXTURE": str(FIXTURES / self.fixture),
            "TMPDIR": self.tmp,
        }
        self.wiz = wizard.Wizard(str(ROOT), self.env)

    def tearDown(self):
        self.wiz.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fill(self, password="s3cret-pass"):
        a = self.wiz.answers
        a.keymap, a.timezone = "us", "UTC"
        a.disk, a.disk_descr, a.disk_size = "ada0", "Samsung SSD 860", 500107862016
        a.user_name, a.full_name, a.hostname = "tester", "Test User", "box1"
        a.network_mode, a.net_if = "dhcp", "em0"
        self.wiz.set_password(password)


class PagesTest(WizardCase):
    def test_the_pages_are_the_pages_of_the_text_front_end(self):
        tui = (ROOT / "bin" / "installer-tui").read_text(encoding="utf-8")
        tui_pages = re.search(r"^PAGES='([^']*)'", tui, re.M).group(1).split()
        self.assertEqual(wizard.PAGE_IDS, tui_pages)
        self.assertEqual(len(wizard.PAGES), 9)

    def test_every_page_has_one_cluster_with_the_primary_last(self):
        for page in wizard.PAGE_IDS + ["preflight"]:
            for kwargs in ({}, {"failed": True}, {"running": True}):
                acts = self.wiz.actions(page, **kwargs)
                if not acts:
                    continue
                primaries = [a for a in acts if a.primary]
                self.assertEqual(len(primaries), 1, (page, kwargs, acts))
                self.assertIs(acts[-1], primaries[0], (page, kwargs))
                self.assertEqual(len({a.ident for a in acts}), len(acts))

    def test_the_welcome_page_offers_the_live_desktop(self):
        acts = self.wiz.actions("welcome")
        self.assertEqual(acts[0].ident, "try-live")
        self.assertEqual(acts[0].label, "Try the live desktop")
        self.assertFalse(acts[0].primary)
        self.assertEqual(acts[-1].label, "Install ExampleBSD")
        self.assertEqual(wizard.EXIT_TRY_LIVE, 10)

    def test_install_is_destructive_and_the_finished_page_reboots(self):
        self.assertTrue(self.wiz.actions("summary")[-1].destructive)
        self.assertEqual(self.wiz.actions("finish")[-1].ident, "reboot")
        self.assertEqual([a.ident for a in self.wiz.actions("install", failed=True)],
                         ["back", "retry"])
        self.assertEqual([a.ident for a in self.wiz.actions("install", running=True)],
                         ["stop"])

    def test_next_and_back_walk_the_order(self):
        self.assertEqual(wizard.Wizard.next_page("disk"), "users")
        self.assertEqual(wizard.Wizard.prev_page("disk"), "timezone")
        self.assertEqual(wizard.Wizard.prev_page("welcome"), "welcome")
        self.assertEqual(wizard.Wizard.next_page("finish"), "finish")

    def test_the_product_and_the_defaults_come_from_the_configuration(self):
        self.assertEqual(self.wiz.product, "ExampleBSD")
        self.assertEqual(self.wiz.answers.keymap, "us")
        self.assertEqual(self.wiz.answers.timezone, "UTC")
        self.assertEqual(self.wiz.logo, "")


class PreflightTest(WizardCase):
    def test_a_machine_with_hardware_passes(self):
        self.assertEqual(self.wiz.preflight(), [])

    def test_a_machine_without_a_disk_lists_requirement_detected_needed(self):
        fixture = os.path.join(self.tmp, "nodisk.conf")
        with open(fixture, "w", encoding="ascii") as stream:
            stream.write("DISKS=\nINTERFACES=em0\n")
        self.wiz.env["INSTALLER_ADAPTER_FIXTURE"] = fixture
        self.wiz.backend.env["INSTALLER_ADAPTER_FIXTURE"] = fixture
        failures = self.wiz.preflight()
        self.assertEqual(len(failures), 1)
        f = failures[0]
        self.assertEqual((f.requirement, f.detected, f.needed),
                         ("A disk to install to", "none found", "one disk"))
        self.assertFalse(f.may_override)
        self.assertEqual([a.ident for a in self.wiz.actions("preflight", failure=f)],
                         ["quit", "rescan"])

    def test_a_machine_without_a_network_may_go_on_offline(self):
        self.wiz.backend.env["INSTALLER_ADAPTER_FIXTURE"] = str(
            FIXTURES / "adapter-fixture-nononet.conf")
        failures = self.wiz.preflight()
        self.assertEqual([f.kind for f in failures], ["network"])
        self.assertTrue(failures[0].may_override)
        self.assertEqual([a.ident for a in self.wiz.actions("preflight", failure=failures[0])],
                         ["quit", "override", "rescan"])
        self.wiz.override(failures[0])
        self.assertEqual(self.wiz.answers.network_mode, "offline")


class UsersTest(WizardCase):
    def test_a_good_account_has_no_error(self):
        self.assertEqual(self.wiz.check_users("tester", "Test User", "pw", "pw", "box1", ""), {})

    def test_the_rules_of_the_text_front_end_apply(self):
        errors = self.wiz.check_users("root", "", "pw", "pw", "", "")
        self.assertIn("a name the system uses", errors["user_name"])
        errors = self.wiz.check_users("Bad Name", "", "pw", "pw", "", "")
        self.assertIn("user_name", errors)
        errors = self.wiz.check_users("", "", "", "", "", "")
        self.assertEqual(set(errors), {"user_name", "password"})

    def test_the_reserved_names_are_the_ones_of_the_shell_rules(self):
        self.assertIn("toor", self.wiz.reserved)
        self.assertIn("operator", self.wiz.reserved)

    def test_the_confirmation_host_name_key_and_full_name_are_checked(self):
        errors = self.wiz.check_users("tester", "A:B", "pw", "pw2", "-bad-", "not a key")
        self.assertEqual(set(errors), {"full_name", "confirm", "hostname", "ssh_key"})
        self.assertEqual(self.wiz.check_users("tester", "", "pw", "pw", "", KEY), {})

    def test_the_password_becomes_a_hash_in_a_private_file(self):
        self.wiz.set_password("s3cret-pass")
        path = self.wiz.hash_file
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertTrue(wizard.private_dir_ok(os.path.dirname(path)))
        with open(path, encoding="ascii") as stream:
            value = stream.read().strip()
        self.assertTrue(value.startswith("$6$"))
        self.assertEqual(passhash.sha512_crypt("s3cret-pass", value), value)

    def test_the_password_is_written_nowhere(self):
        self.fill("s3cret-pass")
        self.wiz.write_answers()
        self.wiz.validate("users")
        for dirpath, _dirs, files in os.walk(self.tmp):
            for name in files:
                with open(os.path.join(dirpath, name), "rb") as stream:
                    self.assertNotIn(b"s3cret-pass", stream.read(), name)

    def test_the_scheme_of_the_adapter_is_used(self):
        self.assertEqual(self.wiz.hash_scheme, "sha512")


class AnswersTest(WizardCase):
    def test_the_answers_are_keys_the_gating_knows(self):
        self.fill()
        self.wiz.answers.ssh_key = KEY
        self.wiz.answers.network_mode = "static"
        keys = {k for k, _v in self.wiz.answers_raw()}
        self.assertTrue(keys <= ANSWER_KEYS, keys - ANSWER_KEYS)

    def test_the_answers_share_their_keys_with_the_text_front_end(self):
        tui = (ROOT / "bin" / "installer-tui").read_text(encoding="utf-8")
        tui_keys = set(re.findall(r"printf '([A-Z_0-9]+)=%s", tui))
        tui_keys |= set(re.findall(r"printf '([A-Z_0-9]+)=static", tui))
        self.fill()
        self.wiz.answers.network_mode = "static"
        gui_keys = {k for k, _v in self.wiz.answers_raw()}
        # Neither front end writes the password itself.
        self.assertEqual(tui_keys - gui_keys, set())
        self.assertNotIn("USER_PASSFILE", tui_keys)
        # The graphical front end asks for more; every extra key is optional.
        self.assertEqual(gui_keys - tui_keys, {"USER_FULLNAME", "HOSTNAME"})

    def test_the_answers_go_through_the_gate(self):
        self.fill()
        self.wiz.answers.network_mode = "offline"
        self.wiz.answers.net_if = ""
        self.wiz.answers.ipv4_addr = "192.0.2.10"
        self.wiz.write_answers()
        with open(self.wiz.answers_file, encoding="utf-8") as stream:
            text = stream.read()
        self.assertNotIn("NET_IF=", text)
        self.assertNotIn("IPV4_ADDR", text)
        self.assertIn(f"USER_HASHFILE={self.wiz.hash_file}\n", text)
        self.assertEqual(stat.S_IMODE(os.stat(self.wiz.answers_file).st_mode), 0o600)
        with open(os.path.join(self.wiz.state, "consumed-secrets.txt"), encoding="ascii") as s:
            self.assertEqual(s.read().split(), ["USER_HASHFILE"])

    def test_a_static_address_is_kept(self):
        self.fill()
        a = self.wiz.answers
        a.network_mode, a.ipv4_addr, a.ipv4_mask, a.ipv4_gw = (
            "static", "192.0.2.10", MASK, "192.0.2.1")
        self.wiz.write_answers()
        with open(self.wiz.answers_file, encoding="utf-8") as stream:
            text = stream.read()
        self.assertIn("IPV4_ADDR=192.0.2.10\n", text)
        self.assertIsNone(self.wiz.leave("network"))

    def test_a_line_break_never_reaches_the_answers(self):
        self.fill()
        self.wiz.answers.full_name = "a\nDISK=ada1"
        with self.assertRaises(ValueError):
            self.wiz.write_answers()

    def test_the_backend_checks_every_page(self):
        self.fill()
        for page in ("keyboard", "timezone", "disk", "users", "network", "summary"):
            self.assertIsNone(self.wiz.leave(page), page)
        self.wiz.answers.disk = "ada9"
        self.assertIn("not present", self.wiz.leave("disk"))
        self.wiz.answers.disk = "ada0"
        self.wiz.answers.user_name = "root"
        self.assertIn("a name the system uses", self.wiz.leave("users"))
        self.wiz.answers.user_name = "tester"
        self.wiz.answers.timezone = "Mars/Olympus"
        self.assertIn("not known", self.wiz.leave("timezone"))

    def test_a_hash_file_without_a_crypt_hash_is_refused(self):
        self.fill()
        with open(self.wiz.hash_file, "w", encoding="ascii") as stream:
            stream.write("not-a-hash\n")
        self.assertIn("holds no crypt hash", self.wiz.leave("users"))

    def test_the_summary_says_what_is_erased(self):
        self.fill()
        rows = dict(self.wiz.summary_rows())
        self.assertEqual(rows["Disk"], "ada0 (Samsung SSD 860, 500 GB)")
        self.assertEqual(rows["User"], "tester (Test User)")
        self.assertIn("ada0", self.wiz.erase_warning())
        self.assertIn("erased", self.wiz.erase_warning())


class KeymapTest(WizardCase):
    def test_console_keymaps_map_to_x_layouts(self):
        cases = {
            "us": ("us", ""), "uk": ("gb", ""), "de": ("de", ""),
            "german.iso": ("de", ""), "us.dvorak": ("us", "dvorak"),
            "de.noacc.kbd": ("de", "nodeadkeys"), "sf": ("ch", "fr"), "sg": ("ch", ""),
            "sv": ("se", ""), "jp106": ("jp", ""), "la": ("latam", ""),
            "spanish.iso.acc": ("es", ""),
        }
        for name, want in cases.items():
            self.assertEqual(wizard.xkb_for(name), want, name)
        self.assertIsNone(wizard.xkb_for("klingon"))
        self.assertEqual(wizard.setxkbmap_argv("us.dvorak"),
                         ["setxkbmap", "us", "-variant", "dvorak"])

    def test_the_chosen_keymap_is_applied_to_the_live_session(self):
        log = os.path.join(self.tmp, "setxkbmap.log")
        self.wiz.env["STUB_SETXKBMAP_LOG"] = log
        self.assertIn("types in de", self.wiz.apply_keymap("de"))
        self.assertIn("types in ch -variant fr", self.wiz.apply_keymap("sf"))
        self.assertIn("no X layout", self.wiz.apply_keymap("klingon"))
        with open(log, encoding="ascii") as stream:
            self.assertEqual(stream.read().splitlines(), ["de", "ch -variant fr"])
        self.assertEqual(self.wiz.applied_keymap, "sf")

    def test_without_setxkbmap_nothing_is_run(self):
        self.wiz.env["PATH"] = self.tmp
        self.assertIn("not installed", self.wiz.apply_keymap("de"))


class ProgressTest(unittest.TestCase):
    def test_the_lines_of_the_backend(self):
        self.assertEqual(wizard.parse_line("PROGRESS 40 writing the files\n"),
                         ("progress", 40, "writing the files"))
        self.assertEqual(wizard.parse_line("PROGRESS 100"), ("progress", 100, ""))
        self.assertEqual(wizard.parse_line("PROGRESS 250 too far"), ("progress", 100, "too far"))
        self.assertEqual(wizard.parse_line("ERROR the disk is gone"),
                         ("error", None, "the disk is gone"))
        self.assertEqual(wizard.parse_line("install: something"),
                         ("log", None, "install: something"))
        self.assertEqual(wizard.parse_line("PROGRESS x y")[0], "log")

    def test_sizes(self):
        self.assertEqual(wizard.human_size(500107862016), "500 GB")
        self.assertEqual(wizard.human_size(1000204886016), "1.0 TB")
        self.assertEqual(wizard.human_size(0), "unknown size")

    def test_ipv4(self):
        self.assertTrue(wizard.ipv4_valid("192.0.2.1"))
        for bad in ("192.0.2", "192.0.2.256", "a.b.c.d", "192.0.2.1.5", ""):
            self.assertFalse(wizard.ipv4_valid(bad), bad)


class InstallTest(WizardCase):
    def run_install(self):
        events = {"progress": [], "log": [], "error": []}
        run = wizard.InstallRun(
            self.wiz, lambda p, t: events["progress"].append((p, t)),
            events["log"].append, events["error"].append)
        code = run.run_blocking()
        return run, code, events

    def test_a_rehearsal_reports_progress_and_finishes(self):
        self.fill()
        run, code, events = self.run_install()
        self.assertEqual(code, 0)
        self.assertEqual([p for p, _t in events["progress"]], [10, 40, 70, 90, 100])
        self.assertTrue(self.wiz.installed)
        self.assertEqual(self.wiz.hash_file, "")
        self.assertFalse(os.path.exists(os.path.join(self.wiz.secrets, "user.hash")))

    def test_the_install_command_gets_the_hash(self):
        self.fill("s3cret-pass")
        del self.wiz.env["INSTALLER_ADAPTER_FIXTURE"]
        del self.wiz.backend.env["INSTALLER_ADAPTER_FIXTURE"]
        info = os.path.join(self.tmp, "disk-info")
        with open(info, "w", encoding="ascii") as stream:
            stream.write("ada0\tSamsung SSD 860\t500107862016\n")
        mounts = self.env["STUB_MOUNTS"]
        copy = os.path.join(self.tmp, "hash-copy")
        self.wiz.env.update(STUB_DISKS="ada0 ada1", STUB_DISK_INFO=info, STUB_MOUNTS=mounts,
                            STUB_INSTALL_HASH_COPY=copy,
                            STUB_INSTALL_ARGS=os.path.join(self.tmp, "args"))
        self.wiz.backend.env = self.wiz.env
        run, code, events = self.run_install()
        self.assertEqual(code, 0, events)
        self.assertEqual(events["progress"][-1], (100, "Done"))
        with open(copy, encoding="ascii") as stream:
            value = stream.read().strip()
        self.assertEqual(passhash.sha512_crypt("s3cret-pass", value), value)

    def test_a_failure_is_reported_and_the_secrets_are_gone(self):
        self.fill()
        self.wiz.backend.env["INSTALLER_ADAPTER_FIXTURE"] = str(
            FIXTURES / "adapter-fixture-fail.conf")
        self.wiz.env["INSTALLER_ADAPTER_FIXTURE"] = str(FIXTURES / "adapter-fixture-fail.conf")
        run, code, events = self.run_install()
        self.assertNotEqual(code, 0)
        self.assertEqual(events["error"], ["the installation failed"])
        self.assertTrue(self.wiz.install_failed)
        self.assertFalse(self.wiz.installed)
        self.assertEqual(self.wiz.hash_file, "")

    def test_stop_ends_the_whole_installation(self):
        self.fill()
        self.wiz.env["INSTALLER_REHEARSAL_STEP_SECONDS"] = "5"
        run = wizard.InstallRun(self.wiz, lambda p, t: None, lambda l: None, lambda e: None)
        self.assertIsNone(run.start())
        first = run.proc.stdout.readline()
        self.assertTrue(first.startswith("PROGRESS 10"), first)
        started = time.monotonic()
        run.stop()
        rest = run.proc.stdout.read()
        code = run.finish()
        self.assertLess(time.monotonic() - started, 4, "the stop waited for the steps")
        self.assertNotEqual(code, 0)
        self.assertTrue(run.stopped)
        self.assertNotIn("PROGRESS 100", rest)
        self.assertTrue(self.wiz.install_failed)
        self.assertEqual(self.wiz.hash_file, "")

    def test_a_stopped_run_fails_although_the_helper_says_0(self):
        # A helper that answers STOP by saying it is done and ending with 0.
        fake = os.path.join(self.tmp, "fake-helper")
        with open(fake, "w", encoding="ascii") as stream:
            stream.write("#!/bin/sh\necho 'PROGRESS 10 writing'\n"
                         "while read line; do [ \"$line\" = STOP ] && break; done\n"
                         "echo 'PROGRESS 100 Done'\nexit 0\n")
        os.chmod(fake, 0o700)
        self.fill()
        self.wiz.install_command = lambda: [fake]
        run = wizard.InstallRun(self.wiz, lambda p, t: None, lambda l: None, lambda e: None)
        self.assertIsNone(run.start())
        self.assertTrue(run.proc.stdout.readline().startswith("PROGRESS 10"))
        run.stop()
        run.proc.stdout.read()
        self.assertNotEqual(run.finish(), 0)
        self.assertTrue(self.wiz.install_failed)
        self.assertFalse(self.wiz.installed)

    def test_the_install_goes_through_the_root_helper(self):
        self.fill()
        argv = self.wiz.install_command()
        self.assertTrue(argv[0].endswith("installer-apply"), argv)
        self.assertEqual(argv[1], "--install")
        self.assertEqual(argv[2], self.wiz.secrets)
        self.assertEqual(sorted(os.listdir(self.wiz.secrets)), ["answers.conf", "user.hash"])
        self.assertEqual(self.wiz.reboot_command()[1:], ["--reboot"])

    def test_the_state_is_gone_after_the_run_and_the_log_kept(self):
        self.fill()
        state = self.wiz.state
        self.wiz.log("a line of the log")
        self.wiz.close()
        self.assertFalse(os.path.exists(state))
        with open(self.env["INSTALLER_LOG"], encoding="utf-8") as stream:
            self.assertIn("a line of the log", stream.read())
        self.assertEqual(stat.S_IMODE(os.stat(self.env["INSTALLER_LOG"]).st_mode), 0o600)


class StateParentTest(unittest.TestCase):
    """Without INSTALLER_STATE_PARENT the state of a run is made in a
    private directory of the user, never in TMPDIR or /tmp."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        os.mkdir(self.home)
        self.cache = os.path.join(self.home, ".cache", "wtfbsd-installer")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def runtime(self, mode):
        path = os.path.join(self.tmp, "runtime")
        os.mkdir(path)
        os.chmod(path, mode)
        return path

    def test_private_runtime_directory(self):
        runtime = self.runtime(0o700)
        env = {"XDG_RUNTIME_DIR": runtime, "HOME": self.home, "TMPDIR": self.tmp}
        self.assertEqual(wizard.private_state_parent(env), runtime)

    def test_runtime_directory_others_may_enter(self):
        env = {"XDG_RUNTIME_DIR": self.runtime(0o755), "HOME": self.home, "TMPDIR": self.tmp}
        self.assertEqual(wizard.private_state_parent(env), self.cache)
        self.assertEqual(os.stat(self.cache).st_mode & 0o777, 0o700)

    def test_no_runtime_directory(self):
        env = {"HOME": self.home, "TMPDIR": self.tmp}
        self.assertEqual(wizard.private_state_parent(env), self.cache)

    def test_cache_directory_that_is_a_link_is_refused(self):
        os.makedirs(os.path.dirname(self.cache))
        os.symlink(self.tmp, self.cache)
        with self.assertRaises(OSError):
            wizard.private_state_parent({"HOME": self.home})

    def test_the_wizard_uses_it(self):
        env = {"HOME": self.home, "TMPDIR": self.tmp, "PATH": os.environ.get("PATH", "")}
        wiz = wizard.Wizard(str(ROOT), env)
        try:
            self.assertEqual(os.path.dirname(wiz.state), self.cache)
        finally:
            shutil.rmtree(wiz.state, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()

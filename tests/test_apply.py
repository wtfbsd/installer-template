# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests for the root helper (lib/apply.py): a stopped installation is a
# failed one, whatever its process group says when it ends.

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

LIB = pathlib.Path(__file__).resolve().parent.parent / "lib"

# The child stands for the installation: it ignores SIGTERM, says it is done
# and ends with 0 when it is told to stop.
STUBBORN = textwrap.dedent("""\
    #!/bin/sh
    trap 'echo "PROGRESS 100 Done anyway"; exit 0' TERM
    echo "PROGRESS 5 Writing the image"
    i=0
    while [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    echo "PROGRESS 100 Done"
""")

DRIVER = textwrap.dedent("""\
    import os, sys
    sys.path.insert(0, sys.argv[1])
    import apply
    apply.BACKEND = sys.argv[2]
    sys.exit(apply.run_install(dict(os.environ)))
""")


class StopTest(unittest.TestCase):
    def run_stubborn(self, how):
        with tempfile.TemporaryDirectory() as tmp:
            child = os.path.join(tmp, "child")
            with open(child, "w", encoding="ascii") as stream:
                stream.write(STUBBORN)
            os.chmod(child, 0o700)
            proc = subprocess.Popen(
                [sys.executable, "-I", "-B", "-c", DRIVER, str(LIB), child],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                env=dict(os.environ, WTFBSD_APPLY_MODE="user"))
            first = proc.stdout.readline()
            self.assertTrue(first.startswith("PROGRESS 5"), first)
            started = time.monotonic()
            if how == "stop":
                proc.stdin.write("STOP\n")
                proc.stdin.flush()
            else:
                proc.terminate()
            rest = proc.stdout.read()
            code = proc.wait()
            proc.stdin.close()
            return code, rest, time.monotonic() - started

    def test_a_stopped_run_fails_although_the_child_says_0(self):
        code, rest, took = self.run_stubborn("stop")
        self.assertEqual(code, 1, rest)
        self.assertIn("ERROR the installation was stopped", rest)
        self.assertLess(took, 8)

    def test_sigterm_to_the_helper_stops_the_run_the_same_way(self):
        code, rest, _took = self.run_stubborn("signal")
        self.assertEqual(code, 1, rest)
        self.assertIn("ERROR the installation was stopped", rest)

    def test_the_end_of_standard_input_does_not_stop_the_run(self):
        # A front end that goes away does not stop an installation that is
        # writing a disk; only STOP or a signal does.
        with tempfile.TemporaryDirectory() as tmp:
            child = os.path.join(tmp, "child")
            with open(child, "w", encoding="ascii") as stream:
                stream.write("#!/bin/sh\necho 'PROGRESS 5 x'\nsleep 0.3\necho 'PROGRESS 100 Done'\n")
            os.chmod(child, 0o700)
            proc = subprocess.run(
                [sys.executable, "-I", "-B", "-c", DRIVER, str(LIB), child],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
                env=dict(os.environ, WTFBSD_APPLY_MODE="user"))
            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("PROGRESS 100 Done", proc.stdout)


class ControlTest(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(LIB))
        import apply  # noqa: E402
        self.apply = apply

    def test_stop_in_one_or_in_pieces(self):
        feed = self.apply.feed_control
        self.assertEqual(feed(b"", b"STOP\n"), (b"", True))
        pending, asked = feed(b"", b"ST")
        self.assertFalse(asked)
        self.assertEqual(feed(pending, b"OP\n"), (b"", True))
        self.assertTrue(feed(b"", b"noise\nSTOP\nmore")[1])
        self.assertFalse(feed(b"", b"STOPPED\nNOSTOP\n")[1])

    def test_the_buffer_never_grows_past_its_bound(self):
        feed = self.apply.feed_control
        pending = b""
        for _ in range(64):
            pending, asked = feed(pending, b"x" * 65536)
            self.assertFalse(asked)
            self.assertLessEqual(len(pending), self.apply.CONTROL_KEEP)
        # A STOP after the flood is still understood.
        self.assertTrue(feed(pending, b"\nSTOP\n")[1])

    def test_a_flood_on_standard_input_does_not_grow_the_helper(self):
        # 32 MiB without a newline to a running helper: it keeps running,
        # stays small and still stops on STOP.
        with tempfile.TemporaryDirectory() as tmp:
            child = os.path.join(tmp, "child")
            with open(child, "w", encoding="ascii") as stream:
                stream.write(STUBBORN)
            os.chmod(child, 0o700)
            proc = subprocess.Popen(
                [sys.executable, "-I", "-B", "-c", DRIVER, str(LIB), child],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                env=dict(os.environ, WTFBSD_APPLY_MODE="user"))
            proc.stdout.readline()
            block = b"x" * (1 << 20)
            for _ in range(32):
                proc.stdin.write(block)
            proc.stdin.flush()
            rss = 0
            try:
                with open(f"/proc/{proc.pid}/status", encoding="ascii") as stream:
                    for line in stream:
                        if line.startswith("VmRSS:"):
                            rss = int(line.split()[1])
            except OSError:
                pass
            proc.stdin.write(b"\nSTOP\n")
            proc.stdin.flush()
            proc.stdout.read()
            self.assertEqual(proc.wait(), 1)
            proc.stdin.close()
            if rss:
                self.assertLess(rss, 30 * 1024, "the helper holds the flood")


class ReadPrivateTest(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(LIB))
        import apply  # noqa: E402
        self.apply = apply
        self.tmp = tempfile.mkdtemp()
        with open(os.path.join(self.tmp, "user.hash"), "w", encoding="ascii") as stream:
            stream.write("x\n")
        os.chmod(os.path.join(self.tmp, "user.hash"), 0o600)
        self.dirfd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)

    def tearDown(self):
        os.close(self.dirfd)
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_file_of_the_user_that_asked_is_read(self):
        self.apply.INVOKER = os.getuid()
        self.assertEqual(self.apply.read_private(self.dirfd, "user.hash", 64, True), "x\n")

    def test_a_file_of_another_user_is_refused_even_in_a_good_directory(self):
        self.apply.INVOKER = os.getuid() + 1
        with self.assertRaises(self.apply.Refused) as caught:
            self.apply.read_private(self.dirfd, "user.hash", 64, True)
        self.assertIn("does not belong", str(caught.exception))

    def test_a_file_that_is_too_large_is_refused(self):
        self.apply.INVOKER = os.getuid()
        with self.assertRaises(self.apply.Refused):
            self.apply.read_private(self.dirfd, "user.hash", 1, True)


class WorkBaseTest(unittest.TestCase):
    """The private copy is never made in a directory everybody may write:
    the runtime directory of the user when it is private, else a 0700
    directory under ~/.cache."""

    def setUp(self):
        sys.path.insert(0, str(LIB))
        import apply  # pylint: disable=import-outside-toplevel
        self.apply = apply
        self.tmp = tempfile.mkdtemp()
        self.saved = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def base_with(self, runtime_mode=None, link=False):
        home = os.path.join(self.tmp, "home")
        os.makedirs(home, exist_ok=True)
        runtime = os.path.join(self.tmp, "runtime")
        if link:
            os.makedirs(runtime + ".real", mode=0o700)
            os.symlink(runtime + ".real", runtime)
        elif runtime_mode is not None:
            os.mkdir(runtime)
            os.chmod(runtime, runtime_mode)
        os.environ["HOME"] = home
        os.environ["XDG_RUNTIME_DIR"] = runtime
        # A TMPDIR that is set: it is never where the copy goes.
        os.environ["TMPDIR"] = os.path.join(self.tmp, "shared")
        return self.apply.user_work_base(), home, runtime

    def test_private_runtime_directory(self):
        base, _home, runtime = self.base_with(0o700)
        self.assertEqual(base, runtime)

    def test_runtime_directory_others_may_enter(self):
        base, home, _runtime = self.base_with(0o755)
        self.assertEqual(base, os.path.join(home, ".cache", "wtfbsd-installer"))
        self.assertEqual(os.stat(base).st_mode & 0o777, 0o700)

    def test_runtime_directory_that_is_a_link(self):
        base, home, _runtime = self.base_with(link=True)
        self.assertEqual(base, os.path.join(home, ".cache", "wtfbsd-installer"))

    def test_cache_directory_that_is_a_link_is_refused(self):
        home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(home, ".cache"))
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.mkdir(elsewhere, 0o700)
        os.symlink(elsewhere, os.path.join(home, ".cache", "wtfbsd-installer"))
        os.environ["HOME"] = home
        os.environ.pop("XDG_RUNTIME_DIR", None)
        with self.assertRaises(self.apply.Refused):
            self.apply.user_work_base()


class RootEnvTest(unittest.TestCase):
    """As root the backend gets the fixed PATH of root, never the PATH of
    the environment."""

    def setUp(self):
        sys.path.insert(0, str(LIB))
        import apply  # noqa: E402
        self.apply = apply
        self.saved = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)

    def test_root_path_is_fixed(self):
        os.environ["PATH"] = "/evil/bin:/usr/bin"
        with mock.patch.object(self.apply, "ROOT_MODE", True):
            env = self.apply.base_env()
        self.assertEqual(env["PATH"],
                         "/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:"
                         "/usr/pkg/sbin:/usr/pkg/bin")
        self.assertEqual(set(env), {"PATH", "HOME", "LANG"})

    def test_a_user_keeps_the_path(self):
        os.environ["PATH"] = "/stub/bin:/usr/bin"
        with mock.patch.object(self.apply, "ROOT_MODE", False):
            env = self.apply.base_env()
        self.assertEqual(env["PATH"], "/stub/bin:/usr/bin")


if __name__ == "__main__":
    unittest.main()


class SecretGatesTest(unittest.TestCase):
    """A secret reaches the install command only when its gate is on: the
    passphrase only with a plan that encrypts, root's hash only for root
    with a password, the Wi-Fi file only with a network."""

    def setUp(self):
        sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
        import apply as A
        self.A = A

    def test_a_passphrase_without_a_plan_is_dropped(self):
        kept = self.A.gate_secrets({}, None, "x", None, None)
        self.assertIsNone(kept["passphrase"])

    def test_a_passphrase_with_a_plan_that_does_not_encrypt_is_dropped(self):
        plan = {"encryption": {"enabled": False, "swap": False}}
        self.assertIsNone(self.A.gate_secrets({}, plan, "a-long-passphrase", None, None)["passphrase"])

    def test_a_passphrase_of_an_encrypting_plan_is_checked(self):
        plan = {"encryption": {"enabled": True, "swap": False}}
        self.assertEqual(self.A.gate_secrets({}, plan, "a-long-passphrase\n", None, None)["passphrase"],
                         "a-long-passphrase")
        for bad in (None, "short", "two\nlines here", "x" * 1025):
            with self.subTest(bad=bad):
                with self.assertRaises(self.A.Refused):
                    self.A.gate_secrets({}, plan, bad, None, None)

    def test_root_and_wifi_follow_their_gates(self):
        kept = self.A.gate_secrets({"ROOT_MODE": "locked", "NETWORK_MODE": "offline"}, None, None,
                                   "$6$x$y\n", '{"if": "iwm0"}')
        self.assertIsNone(kept["root_hash"])
        self.assertIsNone(kept["wifi"])
        kept = self.A.gate_secrets({"ROOT_MODE": "password", "NETWORK_MODE": "dhcp"}, None, None,
                                   "$6$x$y\n", '{"if": "iwm0"}')
        self.assertEqual(kept["root_hash"], "$6$x$y\n")
        self.assertEqual(kept["wifi"], '{"if": "iwm0"}')

    def test_the_helper_checks_roots_hash_itself(self):
        good = "$6$saltsalt$" + "a" * 86
        self.assertEqual(self.A.check_root_hash(good + "\n", "sha512"), good)
        for bad in ("", "$1$md5$hash", good + "\n" + good, "$2b$10$" + "a" * 53, "not a hash"):
            with self.subTest(bad=bad):
                with self.assertRaises(self.A.Refused):
                    self.A.check_root_hash(bad, "sha512")

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests for the password hashing of the installer.

import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

LIB = pathlib.Path(__file__).resolve().parent.parent / "lib"
sys.path.insert(0, str(LIB))

import passhash  # noqa: E402


class Sha512CryptTest(unittest.TestCase):
    # The test vectors of the specification of SHA-512 crypt.
    def test_the_vector_of_the_specification(self):
        self.assertEqual(
            passhash.sha512_crypt("Hello world!", "$6$saltstring"),
            "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI"
            "68u4OTLiBFdcbYEdFCoEOfaS35inz1")

    def test_the_vector_with_rounds(self):
        self.assertEqual(
            passhash.sha512_crypt("Hello world!", "$6$rounds=10000$saltstringsaltstring"),
            "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVN"
            "SnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")

    def test_python_and_the_system_agree(self):
        if passhash.system_crypt("x", "$6$abcdefgh$") is None:
            self.skipTest("this system has no SHA-512 crypt(3)")
        for word in ("", "a", "pässwörd", "x" * 80, "with space"):
            salt = passhash.sha512_salt()
            self.assertEqual(passhash.sha512_crypt(word, salt),
                             passhash.system_crypt(word, salt))


class MakeHashTest(unittest.TestCase):
    def test_every_scheme_has_its_prefix(self):
        for scheme, prefix in passhash.SCHEMES.items():
            if scheme != "sha512" and passhash.system_crypt("x", passhash.bcrypt_salt(prefix)) is None:
                continue
            value = passhash.make_hash("secret", scheme)
            self.assertTrue(value.startswith(prefix), value)
            self.assertNotIn("secret", value)

    def test_two_hashes_of_one_password_differ(self):
        first = passhash.make_hash("secret", "sha512")
        second = passhash.make_hash("secret", "sha512")
        self.assertNotEqual(first, second)

    def test_sha512_works_without_a_system_crypt(self):
        with mock.patch.object(passhash, "_SYSTEM_CRYPT", None):
            value = passhash.make_hash("secret", "sha512")
        self.assertEqual(passhash.sha512_crypt("secret", value), value)

    def test_bcrypt_without_a_system_crypt_fails_loudly(self):
        with mock.patch.object(passhash, "_SYSTEM_CRYPT", None):
            with self.assertRaises(passhash.HashError):
                passhash.make_hash("secret", "bcrypt")

    def test_a_crypt_that_returns_another_scheme_is_refused(self):
        # A crypt(3) that does not know bcrypt and falls back to DES.
        with mock.patch.object(passhash, "_SYSTEM_CRYPT",
                               mock.Mock(return_value=b"abJnggxhB/yWI")):
            with self.assertRaises(passhash.HashError):
                passhash.make_hash("secret", "bcrypt")

    def test_a_hash_that_does_not_check_is_refused(self):
        # A crypt(3) that answers with a well formed hash that is not the
        # hash of the password.
        # The second call (the check) gets another hash back.
        fixed = b"$2b$10$" + b"A" * 53
        other = b"$2b$10$" + b"B" * 53
        with mock.patch.object(passhash, "_SYSTEM_CRYPT",
                               lambda k, s: other if s == fixed else fixed):
            with self.assertRaises(passhash.HashError):
                passhash.make_hash("secret", "bcrypt")

    def test_empty_and_unknown_are_refused(self):
        with self.assertRaises(passhash.HashError):
            passhash.make_hash("", "sha512")
        with self.assertRaises(passhash.HashError):
            passhash.make_hash("a\nb", "sha512")
        with self.assertRaises(passhash.HashError):
            passhash.make_hash("secret", "md5")

    def test_bcrypt_salt_is_22_characters_of_the_bcrypt_alphabet(self):
        salt = passhash.bcrypt_salt("$2b$", 10)
        self.assertTrue(salt.startswith("$2b$10$"))
        body = salt[len("$2b$10$"):]
        self.assertEqual(len(body), 22)
        self.assertTrue(set(body) <= set(passhash.BCRYPT_ALPHABET))


class HashFileTest(unittest.TestCase):
    def test_the_file_is_0600_in_a_0700_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "secrets", "user.hash")
            passhash.write_hash_file(path, "$6$a$b")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)
            with open(path, encoding="ascii") as stream:
                self.assertEqual(stream.read(), "$6$a$b\n")
            self.assertEqual(os.listdir(os.path.dirname(path)), ["user.hash"])

    def test_a_link_in_the_way_is_replaced_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.mkdir(os.path.join(tmp, "s"), 0o700)
            victim = os.path.join(tmp, "victim")
            with open(victim, "w", encoding="ascii") as stream:
                stream.write("keep\n")
            path = os.path.join(tmp, "s", "user.hash")
            os.symlink(victim, path)
            passhash.write_hash_file(path, "$6$a$b")
            with open(victim, encoding="ascii") as stream:
                self.assertEqual(stream.read(), "keep\n")
            self.assertFalse(os.path.islink(path))

    def test_the_command_line_reads_the_password_from_standard_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s", "user.hash")
            proc = subprocess.run(
                [sys.executable, str(LIB / "passhash.py"), "write", "sha512", path],
                input="my-secret\n", text=True, capture_output=True, check=False)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with open(path, encoding="ascii") as stream:
                value = stream.read().strip()
            self.assertEqual(passhash.sha512_crypt("my-secret", value), value)
            proc = subprocess.run(
                [sys.executable, str(LIB / "passhash.py"), "write", "sha512",
                 os.path.join(tmp, "t", "h")],
                input="\n", text=True, capture_output=True, check=False)
            self.assertEqual(proc.returncode, 3)


if __name__ == "__main__":
    unittest.main()

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The password of the first account, turned into a crypt(3) string.

The installed system stores a crypt(3) string, never the password.  The
front end hashes the password in its own process and writes only the hash,
to a file of mode 0600 in a directory of mode 0700.  The password is never
put on a command line and never written to a file.

The adapter of the system names the scheme the system accepts (the
operation hash-scheme):

  sha512     SHA-512 crypt, "$6$" (FreeBSD, DragonFly)
  bcrypt     bcrypt, "$2b$" (OpenBSD)
  bcrypt-2a  bcrypt, "$2a$" (NetBSD: its crypt(3) refuses "$2b$")

The hash is made by the crypt(3) of the system, through ctypes.  When the
system has no usable crypt(3), SHA-512 crypt is computed in Python (the
algorithm is public and short); bcrypt has no such fallback and fails.
Every hash is checked before it is used: crypt(password, hash) has to give
the hash back and the hash has to start with the prefix of the scheme.

The command line reads the password from standard input, so it never
appears in the list of processes:

  printf '%s\\n' "$password" | passhash.py write <scheme> <file>
  passhash.py schemes
"""

from __future__ import annotations

import ctypes
import ctypes.util
import hashlib
import os
import secrets
import stat
import sys
from typing import Callable, Dict, Optional, Tuple

# The alphabet of crypt(3) salts and of the SHA-512 crypt output.
CRYPT_ALPHABET = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# The alphabet of bcrypt, which orders the same characters differently.
BCRYPT_ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

BCRYPT_COST = 10

SCHEMES: Dict[str, str] = {
    "sha512": "$6$",
    "bcrypt": "$2b$",
    "bcrypt-2a": "$2a$",
}


class HashError(Exception):
    """The password could not be turned into a hash the system accepts."""


# ---------------------------------------------------------------- salts


def sha512_salt() -> str:
    """A "$6$" setting with 16 random salt characters."""
    return "$6$" + "".join(secrets.choice(CRYPT_ALPHABET) for _ in range(16)) + "$"


def _bcrypt_b64(data: bytes) -> str:
    """The base 64 encoding of bcrypt (the encode_base64 of OpenBSD)."""
    out = []
    i = 0
    while i < len(data):
        c1 = data[i]
        i += 1
        out.append(BCRYPT_ALPHABET[c1 >> 2])
        c1 = (c1 & 0x03) << 4
        if i >= len(data):
            out.append(BCRYPT_ALPHABET[c1])
            break
        c2 = data[i]
        i += 1
        c1 |= c2 >> 4
        out.append(BCRYPT_ALPHABET[c1])
        c1 = (c2 & 0x0F) << 2
        if i >= len(data):
            out.append(BCRYPT_ALPHABET[c1])
            break
        c2 = data[i]
        i += 1
        c1 |= c2 >> 6
        out.append(BCRYPT_ALPHABET[c1])
        out.append(BCRYPT_ALPHABET[c2 & 0x3F])
    return "".join(out)


def bcrypt_salt(prefix: str = "$2b$", cost: int = BCRYPT_COST) -> str:
    """A bcrypt setting: the prefix, the cost and 22 salt characters."""
    return f"{prefix}{cost:02d}${_bcrypt_b64(secrets.token_bytes(16))}"


# ---------------------------------------------------- the system crypt(3)


def _load_crypt() -> Optional[Callable[[bytes, bytes], Optional[bytes]]]:
    """crypt(3) of the system, or None.

    It lives in libcrypt on FreeBSD, NetBSD, DragonFly and Linux and in the
    C library on OpenBSD.
    """
    candidates = []
    name = ctypes.util.find_library("crypt")
    if name:
        candidates.append(name)
    candidates.append(None)  # the program itself and its C library
    for candidate in candidates:
        try:
            lib = ctypes.CDLL(candidate)
            func = lib.crypt
        except (OSError, AttributeError):
            continue
        func.restype = ctypes.c_char_p
        func.argtypes = [ctypes.c_char_p, ctypes.c_char_p]

        def call(key: bytes, setting: bytes, _func=func) -> Optional[bytes]:
            return _func(key, setting)

        return call
    return None


_SYSTEM_CRYPT = _load_crypt()


def system_crypt(password: str, setting: str) -> Optional[str]:
    """crypt(3) of the system, or None when it has none or it refused."""
    if _SYSTEM_CRYPT is None:
        return None
    try:
        out = _SYSTEM_CRYPT(password.encode("utf-8"), setting.encode("ascii"))
    except (ValueError, OSError):
        return None
    if not out:
        return None
    text = out.decode("ascii", "replace")
    # A crypt(3) that does not know a scheme returns NULL or a string
    # that starts with "*".
    if text.startswith("*"):
        return None
    return text


# ------------------------------------------- SHA-512 crypt in Python


def _sha512_b64(data: bytes) -> str:
    """The output encoding of SHA-512 crypt."""
    order = (
        (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
        (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
        (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
        (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38),
        (18, 39, 60), (40, 61, 19), (62, 20, 41),
    )
    out = []
    for a, b, c in order:
        value = (data[a] << 16) | (data[b] << 8) | data[c]
        for _ in range(4):
            out.append(CRYPT_ALPHABET[value & 0x3F])
            value >>= 6
    value = data[63]
    for _ in range(2):
        out.append(CRYPT_ALPHABET[value & 0x3F])
        value >>= 6
    return "".join(out)


def _sha512_setting(setting: str) -> Tuple[int, bool, bytes]:
    """The rounds, whether they were given, and the salt of a "$6$"
    setting."""
    if not setting.startswith("$6$"):
        raise HashError("not a SHA-512 crypt setting")
    rest = setting[3:]
    rounds = 5000
    custom_rounds = False
    if rest.startswith("rounds="):
        field, _, rest = rest.partition("$")
        try:
            rounds = int(field[len("rounds="):])
        except ValueError as error:
            raise HashError("bad rounds") from error
        rounds = max(1000, min(999999999, rounds))
        custom_rounds = True
    salt = rest.split("$", 1)[0][:16].encode("ascii")
    return rounds, custom_rounds, salt


def _sha512_digest_a(key: bytes, salt: bytes) -> bytes:
    """Steps 1 to 12 of the scheme: the digest A."""
    b = hashlib.sha512(key + salt + key).digest()
    a = hashlib.sha512(key + salt)
    length = len(key)
    while length > 64:
        a.update(b)
        length -= 64
    a.update(b[:length])
    length = len(key)
    while length:
        a.update(b if length & 1 else key)
        length >>= 1
    return a.digest()


def _sha512_rounds(a_digest: bytes, p: bytes, s: bytes, rounds: int) -> bytes:
    """The rounds of the scheme over the sequences P and S."""
    c = a_digest
    for i in range(rounds):
        h = hashlib.sha512()
        h.update(p if i & 1 else c)
        if i % 3:
            h.update(s)
        if i % 7:
            h.update(p)
        h.update(c if i & 1 else p)
        c = h.digest()
    return c


def sha512_crypt(password: str, setting: str) -> str:
    """SHA-512 crypt as specified by its author (the "$6$" scheme)."""
    rounds, custom_rounds, salt = _sha512_setting(setting)
    key = password.encode("utf-8")
    a_digest = _sha512_digest_a(key, salt)

    dp = hashlib.sha512(key * len(key)).digest()
    p = (dp * (len(key) // 64 + 1))[: len(key)]
    ds = hashlib.sha512(salt * (16 + a_digest[0])).digest()
    s = (ds * (len(salt) // 64 + 1))[: len(salt)]

    c = _sha512_rounds(a_digest, p, s, rounds)

    head = "$6$"
    if custom_rounds:
        head += f"rounds={rounds}$"
    return head + salt.decode("ascii") + "$" + _sha512_b64(c)


# ------------------------------------------------------------ the hash


def make_hash(password: str, scheme: str) -> str:
    """The crypt(3) string of the password in the scheme of the system."""
    if scheme not in SCHEMES:
        raise HashError(f"the hash scheme '{scheme}' is not known")
    if password == "":
        raise HashError("the password is empty")
    if "\n" in password or "\0" in password:
        raise HashError("the password holds a line break or a NUL")
    prefix = SCHEMES[scheme]
    if scheme == "sha512":
        setting = sha512_salt()
        result = system_crypt(password, setting)
        if result is None or not result.startswith(prefix):
            result = sha512_crypt(password, setting)
        check = lambda h: (system_crypt(password, h) or sha512_crypt(password, h))  # noqa: E731
    else:
        setting = bcrypt_salt(prefix)
        result = system_crypt(password, setting)
        if result is None:
            raise HashError(
                f"the crypt(3) of this system cannot make a {prefix} hash")
        check = lambda h: system_crypt(password, h)  # noqa: E731
    if not result.startswith(prefix):
        raise HashError(f"the hash does not start with {prefix}")
    if check(result) != result:
        raise HashError("the hash does not check against the password")
    return result


def write_hash_file(path: str, crypt_string: str) -> None:
    """Write the hash to a file of mode 0600 in a directory of mode 0700.

    The directory is made when it is not there.  The file is written in a
    file of its own and moved into place, so a link that is in the way is
    never followed and a reader never sees half a hash.
    """
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode):
        raise HashError(f"{directory} is not a directory")
    if info.st_uid != os.geteuid():
        raise HashError(f"{directory} belongs to another user")
    # nosemgrep: python.lang.security.audit.insecure-file-permissions.insecure-file-permissions -- exactly 0o700 (owner only), on a directory just checked to be ours and not a link
    os.chmod(directory, 0o700)
    tmp = f"{path}.tmp.{os.getpid()}.{secrets.token_hex(4)}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(crypt_string + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv) -> int:
    """The command line; the password is read from standard input."""
    if argv[:1] == ["schemes"]:
        for name, prefix in SCHEMES.items():
            print(f"{name}\t{prefix}")
        return 0
    if len(argv) != 3 or argv[0] != "write":
        print("usage: passhash.py write <scheme> <file> < password", file=sys.stderr)
        print("       passhash.py schemes", file=sys.stderr)
        return 2
    line = sys.stdin.readline()
    password = line[:-1] if line.endswith("\n") else line
    try:
        write_hash_file(argv[2], make_hash(password, argv[1]))
    except (HashError, OSError) as error:
        print(f"passhash: {error}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

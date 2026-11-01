# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The crypt hashes the installer accepts, whole.

The root helper (lib/apply.py) and the users section check a hash file
against these patterns: one line, the whole hash of the scheme.  This
module loads nothing and runs nothing (the root helper imports it).

Usage: hashes.py check SCHEME FILE   (exit 0 when the file is one such hash)
"""

import os
import re
import sys
# The crypt hashes the installer accepts, whole (the root helper and the
# users section check a hash file against them).  re.ASCII: \d is 0 to 9
# only, never another digit of Unicode.
HASH_PATTERNS = {
    "sha512": re.compile(r"\$6\$(rounds=\d{1,9}\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}", re.ASCII),
    "bcrypt": re.compile(r"\$2b\$\d{2}\$[./A-Za-z0-9]{53}", re.ASCII),
    "bcrypt-2a": re.compile(r"\$2a\$\d{2}\$[./A-Za-z0-9]{53}", re.ASCII),
}


def hash_file_ok(path: str, scheme: str) -> bool:
    """A hash file holds exactly one line, a whole crypt hash of the scheme."""
    pattern = HASH_PATTERNS.get(scheme)
    if pattern is None:
        return False
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return False
    try:
        data = os.read(fd, 4097)
    except OSError:
        return False
    finally:
        os.close(fd)
    if len(data) > 4096:
        return False
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return False
    if text.endswith("\n"):
        text = text[:-1]
    return "\n" not in text and bool(pattern.fullmatch(text))


def main(argv) -> int:
    if len(argv) == 3 and argv[0] == "check":
        return 0 if hash_file_ok(argv[2], argv[1]) else 1
    print("usage: hashes.py check <scheme> <file>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The parsers of the illumos adapter (adapters/illumos.sh).

UNPROVEN: written against the documented output formats of the illumos
tools, not against captured outputs.  The adapter uses them in a rehearsal
only until real outputs from an illumos machine prove them (tests then
replay those captures the way tests/test_diskprobe.py does).

  diskinfo -Hp     TYPE<TAB>DISK<TAB>VID<TAB>PID<TAB>SIZE<TAB>RMV<TAB>SSD,
                   SIZE in bytes (diskinfo(8))
  dladm show-phys -p -o link
                   one link name a line (dladm(8))
  kbd_layouts      Name=number lines of
                   /usr/share/lib/keytables/type_6/kbd_layouts (kbd(1))
  policy.conf      CRYPT_DEFAULT=<id> of /etc/security/policy.conf

Usage: illumos.py disks|links|layouts|hash  (the text on standard input)
"""

import re
import sys
from typing import List, Tuple

DISK_RE = re.compile(r"c\d+(t[0-9A-Fa-f]+)?d\d+")
LINK_RE = re.compile(r"[a-z][a-z0-9_]{0,14}\d+")


def disks(text: str) -> List[Tuple[str, str, int]]:
    """(name, description, bytes) of `diskinfo -Hp`; removable media and
    lines that are not disks are left out."""
    out = []
    for line in text.split("\n"):
        f = line.split("\t")
        if len(f) < 7 or not DISK_RE.fullmatch(f[1]) or not f[4].isdigit():
            continue
        if f[5].strip().lower() == "yes" and f[0].upper() in ("CD", "DVD"):
            continue
        descr = " ".join(x.strip() for x in (f[2], f[3]) if x.strip()) or f[1]
        out.append((f[1], descr, int(f[4])))
    return out


def links(text: str) -> List[str]:
    return [l.strip() for l in text.split("\n") if LINK_RE.fullmatch(l.strip())]


def layouts(text: str) -> List[str]:
    out = []
    for line in text.split("\n"):
        name, sep, num = line.strip().partition("=")
        if sep and num.strip().isdigit() and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", name):
            out.append(name)
    return out


def hash_scheme(text: str) -> str:
    """sha512 ($6$): illumos's crypt.conf has it (crypt_sha512) whatever
    CRYPT_DEFAULT says; the installer writes no other scheme for illumos
    (lib/passhash.py makes sha512 and bcrypt).  The policy.conf text is
    read by the CLI (hash) for the day another scheme is written; it does
    not change the answer."""
    del text
    return "sha512"


def main(argv: List[str]) -> int:
    text = sys.stdin.read()
    if len(argv) != 2:
        return 2
    if argv[1] == "disks":
        for name, descr, size in disks(text):
            print(f"{name}\t{descr}\t{size}")
    elif argv[1] == "links":
        print("\n".join(links(text)))
    elif argv[1] == "layouts":
        print("\n".join(layouts(text)))
    elif argv[1] == "hash":
        print(hash_scheme(text))
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

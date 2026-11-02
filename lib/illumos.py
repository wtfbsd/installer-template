# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The parsers of the illumos adapter (adapters/illumos.sh).

Capture-tested on OpenIndiana 2026.10 (tests/fixtures/captures/illumos,
tests/fixtures/hw-captures/illumos, tests/fixtures/illumos): diskinfo,
zpool status, kbd_layouts and policy.conf.  NOT capture-tested yet, written
after the documented formats: /etc/mnttab and dladm scan-wifi.

  diskinfo -Hp     TYPE<TAB>DISK<TAB>VID<TAB>PID<TAB>SIZE<TAB>RMV<TAB>SSD,
                   SIZE in bytes (diskinfo(8))
  dladm show-phys -p -o link
                   one link name a line (dladm(8))
  kbd_layouts      Name=number lines of
                   /usr/share/lib/keytables/type_6/kbd_layouts (kbd(1))
  policy.conf      CRYPT_DEFAULT=<id> of /etc/security/policy.conf
  dladm scan-wifi -p -o essid,secmode,strength
                   ESSID:SECMODE:STRENGTH lines, a colon of the ESSID
                   escaped with a backslash (dladm(8))
  /etc/mnttab      SPECIAL MOUNT_POINT FSTYPE OPTIONS TIME (mnttab(5))

Usage: illumos.py disks|links|layouts|hash|wifi  (the text on standard input)
       illumos.py excluded MNTTAB ZPOOL_RC [--rehearsal]  (zpool status on
       standard input; exit 3 when the disks of the running system cannot
       be told)
"""

import re
import sys
from typing import Dict, List, Optional, Set, Tuple

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


# CRYPT_DEFAULT of policy.conf -> the scheme the installer hashes with.
SCHEMES = {"6": "sha512", "2b": "bcrypt", "2a": "bcrypt-2a"}


def hash_scheme(text: str) -> str:
    """The scheme of CRYPT_DEFAULT in policy.conf (6 on OpenIndiana:
    sha512, crypt_sha512 of crypt.conf); sha512 for a default the
    installer does not write ($5$, md5, __unix__) or none at all: illumos
    allows it by default (CRYPT_ALGORITHMS_ALLOW)."""
    for line in text.split("\n"):
        key, sep, value = line.strip().partition("=")
        if sep and key == "CRYPT_DEFAULT":
            return SCHEMES.get(value.strip(), "sha512")
    return "sha512"


DEV_DISK_RE = re.compile(r"^/dev/r?dsk/(c\d+(?:t[0-9A-F]+)?d\d+)(?:[sp]\d+)?(?::.*)?$")


class Unknown(Exception):
    """The disks of the running system cannot be told: nothing may be
    offered for erasing."""


def excluded(mnttab: str, zpool_status: str) -> List[str]:
    """The disks the running live system needs: the disk the medium is
    mounted from (/.cdrom, or the root itself when it is a disk) and the
    disks of the pool the root is in (a live system started from a pool).
    What it reads and cannot tell is left out (see excluded_checked)."""
    disks, root_pool = _mounted_disks(mnttab)
    if root_pool:
        disks |= pool_members(zpool_status).get(root_pool, set())
    return sorted(disks)


def excluded_checked(mnttab: str, zpool_status: str, zpool_rc: int) -> List[str]:
    """excluded, failing closed (Unknown) when the disks of the running
    system cannot be told: no root in mnttab; a ZFS root whose pool zpool
    status does not list (it failed, or names no disk of the pool); a
    live root (a ramdisk) without the disk of its medium on /.cdrom; a
    root on anything else."""
    root = _mount_entry(mnttab, "/")
    if root is None:
        raise Unknown("no / in /etc/mnttab")
    special, fstype = root
    if fstype == "zfs":
        pool = special.split("/", 1)[0]
        if zpool_rc != 0:
            raise Unknown(f"zpool status failed (exit {zpool_rc}): the disks of {pool} are unknown")
        if not pool_members(zpool_status).get(pool):
            raise Unknown(f"zpool status names no disk of the pool {pool} the system runs from")
    elif not DEV_DISK_RE.match(special):
        if not special.startswith("/devices/ramdisk"):
            raise Unknown(f"the root is on {special}, which is not a disk the installer can name")
        medium = _mount_entry(mnttab, "/.cdrom")
        if not (medium and DEV_DISK_RE.match(medium[0])):
            raise Unknown("a live system whose medium (/.cdrom) is not a disk it can name")
    return excluded(mnttab, zpool_status)


def _mount_entry(mnttab: str, mount: str) -> Optional[Tuple[str, str]]:
    """(special, fstype) of the last mount on a mount point, or None."""
    found = None
    for line in mnttab.split("\n"):
        f = _mnttab_fields(line)
        if len(f) >= 3 and f[1] == mount:
            found = (f[0], f[2])
    return found


def _mnttab_fields(line: str) -> List[str]:
    return line.split("\t") if "\t" in line else line.split()


def _mounted_disks(mnttab: str) -> Tuple[Set[str], Optional[str]]:
    """The disks under / and /.cdrom of mnttab, and the pool of a ZFS root."""
    disks = set()
    root_pool = None
    for line in mnttab.split("\n"):
        f = _mnttab_fields(line)
        if len(f) < 3:
            continue
        special, mount, fstype = f[0], f[1], f[2]
        if mount in ("/.cdrom", "/"):
            m = DEV_DISK_RE.match(special)
            if m:
                disks.add(m.group(1))
        if mount == "/" and fstype == "zfs":
            root_pool = special.split("/", 1)[0]
    return disks, root_pool


POOL_RE = re.compile(r"^pool: (\S+)$")
MEMBER_RE = re.compile(r"(c\d+(?:t[0-9A-F]+)?d\d+)(?:[sp]\d+)?")


def pool_members(text: str) -> Dict[str, Set[str]]:
    """{pool: its disks} of `zpool status` or `zpool import`: the devices of
    each pool's configuration, a slice or partition (c2t0d0s0, c2t0d0p1)
    counted as its disk.  The one reader of that format (lib/diskprobe.py
    uses it too)."""
    found: Dict[str, Set[str]] = {}
    pool = None
    for raw in text.split("\n"):
        line = raw.strip()
        m = POOL_RE.match(line)
        if m:
            pool = m.group(1)
            found.setdefault(pool, set())
            continue
        word = line.split(" ", 1)[0] if line else ""
        m = MEMBER_RE.fullmatch(word)
        if pool and m:
            found[pool].add(m.group(1))
    return found


# The strength words of dladm scan-wifi, as a signal in per cent.
STRENGTH = {"very weak": 10, "weak": 30, "good": 55, "very good": 75, "excellent": 95}


def wifi(text: str) -> List[Tuple[str, str, int]]:
    """(ssid, security, signal %) of `dladm scan-wifi -p -o
    essid,secmode,strength`; security is open, wep or wpa2 (dladm says
    wpa for WPA and WPA2)."""
    out = []
    for line in text.split("\n"):
        fields, cur, esc = [], "", False
        for ch in line:
            if esc:
                cur, esc = cur + ch, False
            elif ch == "\\":
                esc = True
            elif ch == ":":
                fields.append(cur)
                cur = ""
            else:
                cur += ch
        fields.append(cur)
        if len(fields) != 3 or not fields[0] or "|" in fields[0] or \
                any(ord(c) < 32 for c in fields[0]):
            continue
        sec = {"none": "open", "wep": "wep", "wpa": "wpa2"}.get(fields[1].strip().lower())
        if sec is None:
            continue
        out.append((fields[0][:32], sec, STRENGTH.get(fields[2].strip().lower(), 0)))
    return out


def _print_excluded(path: str, status: str, rc: int, rehearsal: bool) -> int:
    """excluded MNTTAB ZPOOL_RC [--rehearsal] (zpool status on stdin): the
    disks, or exit 3 when they cannot be told.  A rehearsal on a machine
    without /etc/mnttab (a test machine) excludes nothing."""
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            mnttab = stream.read(1 << 20)
    except OSError:
        if rehearsal:
            return 0
        sys.stderr.write(f"cannot tell which disks hold the running system: cannot read {path}\n")
        return 3
    try:
        print("\n".join(excluded_checked(mnttab, status, rc)))
    except Unknown as error:
        sys.stderr.write(f"cannot tell which disks hold the running system: {error}\n")
        return 3
    return 0


def main(argv: List[str]) -> int:
    text = sys.stdin.read()
    if len(argv) in (4, 5) and argv[1] == "excluded" and argv[3].isdigit():
        return _print_excluded(argv[2], text, int(argv[3]), argv[4:] == ["--rehearsal"])
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
    elif argv[1] == "wifi":
        for ssid, sec, signal in wifi(text):
            print(f"{ssid}|{sec}|{signal}")
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

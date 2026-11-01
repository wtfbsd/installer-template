# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""What is on the disks now: the disk report of the disk page, per system.

The adapter of a system runs this module (as root, from the root helper's
--list disks) with the disks that may be written to:

    python3 -I lib/diskprobe.py freebsd|netbsd|openbsd|dragonfly DISK...

and prints the report the disk page shows ({"disks": [...]}: size, serial,
partition table, partitions with what they hold, the operating systems found,
the free space, the RAID arrays a disk belongs to).

Everything here only reads:

- the tools of the system, run by their absolute paths (no PATH lookup),
  with an empty environment: sysctl, diskinfo, gpart, fstyp and zpool
  import on FreeBSD; gpt, dkctl, fdisk, fstyp and raidctl on NetBSD;
  fdisk, disklabel and bioctl on OpenBSD; gpt and fstyp on DragonFly;
- the first MiB and the last sector of a disk or partition, opened
  read-only, for the signatures the tools do not know: LUKS, BitLocker,
  GELI, a ZFS label, and whether a disk without a table holds anything;
- the names of the files of an EFI system partition, read from its FAT
  directories in userland (lib/fatdir.py), never mounted, to tell which
  systems boot from it.

What the captures of the real tools showed (tests/fixtures/captures) and
this module handles: FreeBSD fstyp knows neither GELI nor whole-disk ZFS
nor LUKS2 (the signatures do; zpool import names the pool); NetBSD and
OpenBSD assemble foreign RAID members by themselves (RAIDframe raid0,
softraid sd8): the members are shown as members of the array and the
array is not a disk to install to; NetBSD numbers its wedges (dkN) anew at
every boot, so a wedge is matched to its partition by its start, never by
its number; OpenBSD gives an NTFS partition the disklabel type MSDOS, so
the partition table type wins over the disklabel; the file names of an
EFI system partition come upper-case on OpenBSD.

The parsing is separate from the running: tests replay the captured
outputs through a Replay runner.
"""

import json
import os
import re
import subprocess
import sys

# Run as a script with python3 -I: the directory of the script is not on
# the path, the module next to it is named explicitly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fatdir  # noqa: E402
from typing import Callable, Dict, List, Optional, Tuple

MiB = 1024 * 1024

WINDOWS_RECOVERY = "Windows recovery"
# The name of a disk (vtbd1, ld0, sd2): [0-9] only, never another digit.
DISK_NAME_RE = re.compile(r"[a-z]+\d+", re.ASCII)
# hw.disknames of NetBSD and OpenBSD, and the key of its capture.
HW_DISKNAMES = "hw.disknames"
HW_DISKNAMES_KEY = "sysctl_-n_" + HW_DISKNAMES

# ------------------------------------------------------------ partition types

# GPT partition type GUIDs: (type, kind of the bar, what it is).
GPT_TYPES = {
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b": ("efi", "efi", "EFI system"),
    "21686148-6449-6e6f-744e-656564454649": ("bios-boot", "other", "BIOS boot"),
    "e3c9e316-0b5c-4db8-817d-f92df00215ae": ("msr", "msr", "Microsoft reserved"),
    "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7": ("basic-data", "data", "Basic data"),
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac": ("windows-recovery", "recovery", WINDOWS_RECOVERY),
    "0fc63daf-8483-4772-8e79-3d69d8477de4": ("linux-data", "linux", "Linux"),
    "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f": ("linux-swap", "swap", "Linux swap"),
    "e6d6d379-f507-44c2-a23c-238f2a3df928": ("linux-lvm", "linux", "Linux LVM"),
    "a19d880f-05fc-4d3b-a006-743f0f84911e": ("linux-raid", "raid", "Linux RAID member"),
    "ca7d7ccb-63ed-4c53-861c-1742536059cc": ("linux-luks", "encrypted", "LUKS"),
    "bc13c2ff-59e6-4262-a352-b275fd6f7172": ("linux-boot", "linux", "Linux boot"),
    "4f68bce3-e8cd-4db1-96e7-fbcaf984b709": ("linux-root", "linux", "Linux root"),
    "933ac7e1-2eb4-4f13-b844-0e14e2aef915": ("linux-home", "linux", "Linux home"),
    "83bd6b9d-7f41-11dc-be0b-001560b84f0f": ("freebsd-boot", "bsd", "FreeBSD boot"),
    "516e7cb4-6ecf-11d6-8ff8-00022d09712b": ("freebsd", "bsd", "FreeBSD"),
    "516e7cb5-6ecf-11d6-8ff8-00022d09712b": ("freebsd-swap", "swap", "FreeBSD swap"),
    "516e7cb6-6ecf-11d6-8ff8-00022d09712b": ("freebsd-ufs", "bsd", "FreeBSD UFS"),
    "516e7cb8-6ecf-11d6-8ff8-00022d09712b": ("freebsd-vinum", "raid", "FreeBSD vinum"),
    "516e7cba-6ecf-11d6-8ff8-00022d09712b": ("freebsd-zfs", "bsd", "FreeBSD ZFS"),
    "824cc7a0-36a8-11e3-890a-952519ad3f61": ("openbsd-data", "bsd", "OpenBSD"),
    "49f48d32-b10e-11dc-b99b-0019d1879648": ("netbsd-swap", "swap", "NetBSD swap"),
    "49f48d5a-b10e-11dc-b99b-0019d1879648": ("netbsd-ffs", "bsd", "NetBSD FFS"),
    "49f48d82-b10e-11dc-b99b-0019d1879648": ("netbsd-lfs", "bsd", "NetBSD LFS"),
    "49f48daa-b10e-11dc-b99b-0019d1879648": ("netbsd-raid", "raid", "NetBSD RAIDframe member"),
    "2db519c4-b10f-11dc-b99b-0019d1879648": ("netbsd-ccd", "raid", "NetBSD ccd member"),
    "2db519ec-b10f-11dc-b99b-0019d1879648": ("netbsd-cgd", "encrypted", "NetBSD cgd"),
    "9d087404-1ca5-11dc-8817-01301bb8a9f5": ("dragonfly-label32", "bsd", "DragonFly"),
    "3d48ce54-1d16-11dc-8696-01301bb8a9f5": ("dragonfly-label64", "bsd", "DragonFly"),
    "9d58fdbd-1ca5-11dc-8817-01301bb8a9f5": ("dragonfly-swap", "swap", "DragonFly swap"),
    "9d94ce7c-1ca5-11dc-8817-01301bb8a9f5": ("dragonfly-ufs", "bsd", "DragonFly UFS"),
    "61dc63ac-6e38-11dc-8513-001b2156c18e": ("dragonfly-hammer", "bsd", "DragonFly HAMMER"),
    "5cbb9ad1-862d-11dc-a94d-01301bb8a9f5": ("dragonfly-hammer2", "bsd", "DragonFly HAMMER2"),
    "48465300-0000-11aa-aa11-00306543ecac": ("apple-hfs", "other", "macOS HFS+"),
    "7c3457ef-0000-11aa-aa11-00306543ecac": ("apple-apfs", "other", "macOS APFS"),
    "6a898cc3-1dd2-11b2-99a6-080020736631": ("solaris-zfs", "other", "ZFS"),
}

# MBR partition ids.
MBR_TYPES = {
    0x01: ("fat", "data", "FAT"), 0x04: ("fat", "data", "FAT"), 0x06: ("fat", "data", "FAT"),
    0x0b: ("fat", "data", "FAT32"), 0x0c: ("fat", "data", "FAT32"), 0x0e: ("fat", "data", "FAT"),
    0x07: ("basic-data", "data", "NTFS or exFAT"), 0x27: ("windows-recovery", "recovery", WINDOWS_RECOVERY),
    0x82: ("linux-swap", "swap", "Linux swap"), 0x83: ("linux-data", "linux", "Linux"),
    0x8e: ("linux-lvm", "linux", "Linux LVM"), 0xfd: ("linux-raid", "raid", "Linux RAID member"),
    0xa5: ("freebsd", "bsd", "FreeBSD"), 0xa6: ("openbsd-data", "bsd", "OpenBSD"),
    0xa9: ("netbsd", "bsd", "NetBSD"), 0x6c: ("dragonfly", "bsd", "DragonFly"),
    0xef: ("efi", "efi", "EFI system"), 0xee: ("gpt-protective", "other", "GPT"),
    0xaf: ("apple-hfs", "other", "macOS HFS+"),
}

# The names the tools give a type instead of the GUID.
NAMED_TYPES = {
    # OpenBSD fdisk (GPT)
    "efi sys": "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
    "microsoft basic data": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
    "win recovery": "de94bba4-06d1-4d40-a16a-bfd50179d6ac",
    "linux files*": "0fc63daf-8483-4772-8e79-3d69d8477de4",
    "linux swap": "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f",
    "openbsd": "824cc7a0-36a8-11e3-890a-952519ad3f61",
    "freebsd": "516e7cb4-6ecf-11d6-8ff8-00022d09712b",
    # DragonFly gpt show
    "efi system": "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
    "ms reserved": "e3c9e316-0b5c-4db8-817d-f92df00215ae",
    "ms/linux basic data": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
    "freebsd swap": "516e7cb5-6ecf-11d6-8ff8-00022d09712b",
    "freebsd ufs/ufs2": "516e7cb6-6ecf-11d6-8ff8-00022d09712b",
    "freebsd zfs": "516e7cba-6ecf-11d6-8ff8-00022d09712b",
    "dragonfly label32": "9d087404-1ca5-11dc-8817-01301bb8a9f5",
    "dragonfly label64": "3d48ce54-1d16-11dc-8696-01301bb8a9f5",
    "dragonfly swap": "9d58fdbd-1ca5-11dc-8817-01301bb8a9f5",
    "dragonfly hammer2": "5cbb9ad1-862d-11dc-a94d-01301bb8a9f5",
}

GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# fstyp names, as the disk page shows them.
FS_NAMES = {"msdosfs": "FAT", "ntfs": "NTFS", "ext2fs": "ext2/3/4", "ufs": "UFS", "zfs": "ZFS",
            "hammer": "HAMMER", "hammer2": "HAMMER2", "exfat": "exFAT", "iso9660": "ISO 9660",
            "cd9660": "ISO 9660", "ffs": "FFS", "4.2bsd": "FFS", "msdos": "FAT", "apfs": "APFS",
            "hfs+": "HFS+", "swap": "swap"}

# The directories of EFI/ that tell which system boots from an EFI system
# partition, by their lower-case name.
EFI_SYSTEMS = {
    "debian": ("Linux", "Debian"), "ubuntu": ("Linux", "Ubuntu"), "fedora": ("Linux", "Fedora"),
    "opensuse": ("Linux", "openSUSE"), "centos": ("Linux", "CentOS"), "redhat": ("Linux", "Red Hat"),
    "rocky": ("Linux", "Rocky Linux"), "almalinux": ("Linux", "AlmaLinux"),
    "arch": ("Linux", "Arch Linux"), "manjaro": ("Linux", "Manjaro"), "pop": ("Linux", "Pop!_OS"),
    "elementary": ("Linux", "elementary OS"), "kali": ("Linux", "Kali Linux"),
    "gentoo": ("Linux", "Gentoo"), "void": ("Linux", "Void Linux"), "nixos": ("Linux", "NixOS"),
    "mageia": ("Linux", "Mageia"), "neon": ("Linux", "KDE neon"),
    "freebsd": ("FreeBSD", "FreeBSD"), "netbsd": ("NetBSD", "NetBSD"),
    "openbsd": ("OpenBSD", "OpenBSD"), "dragonfly": ("DragonFly", "DragonFly"),
}

# ------------------------------------------------------------------ runners


class Runner:
    """Runs the read-only tools of the system: (exit status, output)."""

    def run(self, key: str, argv: List[str]) -> Tuple[int, str]:
        raise NotImplementedError

    def esp_files(self, os_name: str, dev: str, disk: str = "", offset: int = 0,
                  length: int = 0) -> Optional[List[str]]:
        """The paths of the files and directories of an EFI system
        partition, relative to its root, or None.  The base runner reads
        no partition: a runner that can read one overrides this."""
        del os_name, dev, disk, offset, length
        return None

    def sniff(self, disk: str, offset: int, length: int, dev: str = "") -> dict:
        """The signatures of a region of a disk, a partition or the whole
        disk, read through the whole-disk device (see sniff_bytes): a
        partition the system maps to no device of its own is read too.
        The base runner reads nothing: a runner that can read overrides
        this."""
        del disk, offset, length, dev
        return {}


class Replay(Runner):
    """Outputs captured on a real system: <dir>/<key>.out and .rc, in the
    first of the directories (separated by ':') that has it.  A capture
    that is not there is a failed command (exit 1, nothing)."""

    def __init__(self, directory: str, sniffs: Optional[Dict[str, dict]] = None):
        # sniffs: what the signature read finds, by "disk" (the whole disk)
        # or "disk:start sector" (a partition).
        self.directory = directory
        self.sniffs = sniffs or {}
        self.keys: List[str] = []

    def _read(self, key):
        for directory in self.directory.split(":"):
            alias = self.alias(directory)
            if alias and not os.path.exists(os.path.join(directory, key + ".out")):
                old, new = alias
                renamed = re.sub(rf"(?<![a-z]){old}(?=(p|s)?\d*$|_)", new, key)
                if renamed != key and os.path.exists(os.path.join(directory, renamed + ".out")):
                    key = renamed
            try:
                with open(os.path.join(directory, key + ".out"), encoding="utf-8",
                          errors="replace") as stream:
                    out = stream.read()
                with open(os.path.join(directory, key + ".rc"), encoding="utf-8") as stream:
                    rc = int(stream.read().strip() or "1")
            except (OSError, ValueError):
                continue
            return rc, out
        return 1, ""

    def run(self, key, argv):
        self.keys.append(key)
        return self._read(key)

    def alias(self, directory):
        """The disk of a layout under the name it had in the first boot and
        in the follow-up boot ("vtbd4", "vtbd3"), or None.  A follow-up
        capture (dd_first4k_od_*) names the disk of that boot; the disk of
        the first boot is the one diskinfo was captured for.  Both are the
        one disk of the layout directory."""
        try:
            names = os.listdir(directory)
        except OSError:
            return None
        first = {m.group(1) for n in names for m in [re.match(r"^diskinfo_-v_(\w+)\.out$", n)] if m}
        second = {m.group(1) for n in names
                  for m in [re.match(r"^dd_first4k_od_([a-z]+\d+)\.out$", n)] if m}
        if len(first) == 1 and len(second) == 1 and first != second:
            return first.pop(), second.pop()
        return None

    def esp_files(self, os_name, dev, disk="", offset=0, length=0):
        # A wedge is captured with the disk that holds it (dk2_ld2).
        for key in (f"ls_-R_esp_{dev}", f"ls_-R_esp_{dev}_{disk}"):
            rc, out = self._read(key)
            if rc == 0 and out:
                return parse_ls_r(out)
        return None

    def sniff(self, disk, offset, length, dev=""):
        key = disk if offset == 0 and disk in self.sniffs else f"{disk}:{offset // 512}"
        if key in self.sniffs:
            return dict(self.sniffs[key])
        # The first 4 KiB as `od -A d -t x1`, when it was captured.
        rc, out = self._read(f"dd_first4k_od_{dev or disk}")
        if rc != 0 or not out.strip():
            return {}
        head = parse_od(out)
        return sniff_bytes(head, b"") if head is not None else {}


# The tools by their absolute path, the first that exists.
TOOLS = {
    "sysctl": ["/sbin/sysctl", "/usr/sbin/sysctl"],
    "diskinfo": ["/usr/sbin/diskinfo"],
    "gpart": ["/sbin/gpart"],
    "fstyp": ["/usr/sbin/fstyp", "/sbin/fstyp"],
    "zpool": ["/sbin/zpool"],
    "geli": ["/sbin/geli"],
    "zdb": ["/usr/sbin/zdb", "/sbin/zdb", "/usr/bin/zdb"],
    "gpt": ["/sbin/gpt"],
    "dkctl": ["/sbin/dkctl"],
    "fdisk": ["/sbin/fdisk"],
    "disklabel": ["/sbin/disklabel"],
    "raidctl": ["/sbin/raidctl"],
    "bioctl": ["/sbin/bioctl"],
}


def tool(name: str) -> Optional[str]:
    for path in TOOLS.get(name, []):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


class System(Runner):
    """The tools of the running system."""

    ENV = {"PATH": "/sbin:/bin:/usr/sbin:/usr/bin", "LC_ALL": "C"}

    def __init__(self, os_name: str):
        self.os_name = os_name

    def whole_disk(self, disk: str) -> str:
        """The raw device of a whole disk."""
        if self.os_name == "netbsd":
            part = "d" if os.uname().machine in ("amd64", "i386") else "c"
            return f"/dev/r{disk}{part}"
        if self.os_name == "openbsd":
            return f"/dev/r{disk}c"
        return f"/dev/{disk}"

    def run(self, key, argv):
        path = tool(argv[0])
        if path is None:
            return 127, ""
        try:
            proc = subprocess.run([path] + argv[1:], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=dict(self.ENV), timeout=30, check=False, cwd="/")
        except (OSError, subprocess.TimeoutExpired):
            return 1, ""
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    def esp_files(self, os_name, dev, disk="", offset=0, length=0):
        # The partition is never mounted: its FAT directories are read in
        # userland (lib/fatdir.py) through the whole-disk device, read only.
        if not DISK_NAME_RE.fullmatch(disk) or offset % 512 or length < 512:
            return None
        try:
            fd = os.open(self.whole_disk(disk), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return None
        try:
            def read(pos, size):
                # Raw devices read whole sectors.
                start = (offset + pos) // 512 * 512
                end = -(-(offset + pos + size) // 512) * 512
                data = os.pread(fd, end - start, start)
                skip = offset + pos - start
                return data[skip:skip + size]
            return fatdir.list_files(read, length)
        except OSError:
            return None
        finally:
            os.close(fd)

    def sniff(self, disk, offset, length, dev=""):
        if not DISK_NAME_RE.fullmatch(disk) or offset % 512 or length < 512:
            return {}
        try:
            fd = os.open(self.whole_disk(disk), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            return {}
        try:
            head = os.pread(fd, min(MiB, length - length % 512), offset)
            tail = os.pread(fd, 512, offset + length - length % 512 - 512)
        except OSError:
            return {}
        finally:
            os.close(fd)
        return sniff_bytes(head, tail)


# --------------------------------------------------------------- signatures

ZFS_UBERBLOCK = (0x00bab10c).to_bytes(8, "little"), (0x00bab10c).to_bytes(8, "big")


def sniff_bytes(head: bytes, tail: bytes) -> dict:
    """The signatures in the first MiB and the last sector of a disk or
    partition: {"signature": luks|bitlocker|geli|zfs|"", "empty": bool}.
    empty: the first MiB is all zeros."""
    sig = ""
    if head[:6] == b"LUKS\xba\xbe" or head[:6] == b"SKUL\xba\xbe":
        sig = "luks"
    elif head[3:11] == b"-FVE-FS-":
        sig = "bitlocker"
    elif tail[:9] == b"GEOM::ELI":
        sig = "geli"
    else:
        for k in range(128):
            off = 128 * 1024 + k * 1024
            if head[off:off + 8] in ZFS_UBERBLOCK:
                sig = "zfs"
                break
    return {"signature": sig, "empty": not head.strip(b"\0")}


# ------------------------------------------------------------------ helpers


def parse_od(text: str) -> Optional[bytes]:
    """The bytes of an `od -A d -t x1` dump; a line "*" repeats the line
    before it up to the next offset."""
    data = bytearray()
    last = b""
    repeat = False
    for raw in text.split("\n"):
        line = raw.strip()
        if not line:
            continue
        if line == "*":
            repeat = True
            continue
        words = line.split()
        if not words[0].isdigit():
            return None
        offset = int(words[0])
        if repeat and last:
            while len(data) + len(last) <= offset:
                data += last
            repeat = False
        row = bytes(int(w, 16) for w in words[1:])
        if row:
            data = data[:offset] + row
            last = row
    return bytes(data)


def parse_ls_r(text: str) -> List[str]:
    """The paths of an `ls -R` from the root of a file system."""
    files = []
    current = ""
    lines = text.split("\n")
    for index, line in enumerate(lines):
        if not line:
            continue
        if line.endswith(":") and (index == 0 or not lines[index - 1]):
            current = line[:-1]
            current = "" if current in (".", "./") else current
            current = current[2:] if current.startswith("./") else current
            continue
        files.append(f"{current}/{line}" if current else line)
    return files


def classify(guid: Optional[str] = None, mbr: Optional[int] = None,
             name: str = "") -> Tuple[str, str, str]:
    """(type, kind, what) of a partition from its GPT type, MBR id or the
    name a tool gives it."""
    if not guid and name:
        low = name.strip().lower()
        if GUID_RE.match(low):
            guid = low
        else:
            guid = NAMED_TYPES.get(low)
    if guid:
        return GPT_TYPES.get(guid.lower(), ("other", "other", "Unknown"))
    if mbr is not None:
        return MBR_TYPES.get(mbr, ("other", "other", f"MBR type {mbr:#04x}"))
    return ("other", "other", "Unknown")


def part(dev: str, start: int, size: int, sector: int, guid=None, mbr=None, name="",
         label="", fs="") -> dict:
    ptype, kind, what = classify(guid, mbr, name)
    return {"dev": dev, "start": start, "sectors": size, "sector": sector,
            "type": ptype, "kind": kind, "what": what, "gpt_label": label, "fs": fs}


def fstyp_name(rc: int, out: str) -> str:
    if rc != 0:
        return ""
    word = out.strip().split("\n")[0].strip().lower() if out.strip() else ""
    return FS_NAMES.get(word, word)


# ------------------------------------------------------------------ FreeBSD


def _gpart_provider_line(line: str, current: Optional[dict], parts: List[dict]) -> Optional[dict]:
    """One line of the Providers of `gpart list`: a new provider, or a key
    of the provider before it.  The provider the next line belongs to."""
    m = re.match(r"^\d+\. Name: (\S+)$", line)
    if m:
        current = {"dev": m.group(1)}
        parts.append(current)
        return current
    if current is not None and ":" in line:
        key, value = line.split(":", 1)
        current[key.strip()] = value.strip()
    return current


def _gpart_providers(text: str) -> Tuple[str, List[dict]]:
    """The scheme and the providers (their keys) of `gpart list DISK`."""
    scheme = ""
    parts: List[dict] = []
    current: Optional[dict] = None
    in_providers = False
    for raw in text.split("\n"):
        line = raw.strip()
        if line.startswith("scheme:") and not scheme:
            scheme = line.split(":", 1)[1].strip()
        if line == "Providers:":
            in_providers = True
            continue
        if line == "Consumers:":
            in_providers = False
            current = None
            continue
        if in_providers:
            current = _gpart_provider_line(line, current, parts)
    return scheme, parts


def _gpart_part(p: dict, sector: int) -> Optional[dict]:
    """The partition of a provider of `gpart list`, or None."""
    try:
        start = int(p.get("start", "0"))
        length = int(p.get("length", "0")) // sector
    except ValueError:
        return None
    raw = p.get("rawtype", "")
    guid = raw if GUID_RE.match(raw) else None
    mbr = int(raw) if raw.isdigit() else None
    return part(p["dev"], start, length, sector, guid=guid, mbr=mbr, label=p.get("label", ""))


def freebsd_gpart_list(text: str, sector: int) -> Tuple[str, List[dict]]:
    """scheme and partitions of `gpart list DISK`."""
    scheme, parts = _gpart_providers(text)
    out = []
    for p in parts:
        entry = _gpart_part(p, sector)
        if entry is not None:
            out.append(entry)
    return scheme.upper() if scheme else "", out


def freebsd_zpool_import(text: str) -> Dict[str, str]:
    """{device: pool} of `zpool import`."""
    found = {}
    pool = None
    in_config = False
    for raw in text.split("\n"):
        line = raw.strip()
        m = re.match(r"^pool: (\S+)$", line)
        if m:
            pool = m.group(1)
            in_config = False
            continue
        if line == "config:":
            in_config = True
            continue
        if in_config and pool and line:
            word = line.split()[0]
            if word not in (pool, "mirror", "raidz", "raidz1", "raidz2", "raidz3", "logs",
                            "cache", "spares", "special", "dedup") and \
                    not re.match(r"^(mirror|raidz\d?)-\d+$", word):
                dev = word.split("/")[-1]
                found[dev] = pool
    return found


def without_note(key: str) -> str:
    """A key of `diskinfo -v` without its note in parentheses at the end
    ("mediasize in bytes (1.0G)"): what re.sub(r"\\s*\\(.*\\)$", "", key)
    gives for a line (no newline in it), read in one pass."""
    if not key.endswith(")"):
        return key
    opening = key.find("(")
    if opening < 0:
        return key
    return key[:opening].rstrip()


def _diskinfo(runner: Runner, name: str) -> Dict[str, str]:
    """{key: value} of `diskinfo -v DISK`."""
    info = {}
    _rc, out = runner.run(f"diskinfo_-v_{name}", ["diskinfo", "-v", name])
    for raw in out.split("\n"):
        if "#" in raw:
            value, key = raw.split("#", 1)
            info[without_note(key.strip())] = value.strip()
    return info


def _solid_state(rate: str) -> Optional[bool]:
    """Whether a disk is an SSD by its rotation rate: 0 is, more than 1
    RPM is not, anything else is not known."""
    if rate == "0":
        return True
    if rate.isdigit() and int(rate) > 1:
        return False
    return None


def _freebsd_disk(name: str, info: Dict[str, str]) -> dict:
    """The disk of `diskinfo -v`, before its partitions."""
    sector = int(info.get("sectorsize") or 512) if (info.get("sectorsize") or "").isdigit() else 512
    size = int(info["mediasize in bytes"]) if info.get("mediasize in bytes", "").isdigit() else 0
    return {"name": name, "size_bytes": size, "sector": sector,
            "model": info.get("Disk descr.", ""), "serial": info.get("Disk ident.", ""),
            "bus": bus_of(name, info.get("Attachment", "")),
            "ssd": _solid_state(info.get("Rotation rate in RPM", ""))}


def _is_geli(runner: Runner, dev: str) -> bool:
    # fstyp and zpool import do not see a GELI provider: geli dump reads
    # its metadata (the last sector) and changes nothing.
    rc, out = runner.run(f"geli_dump_{dev}", ["geli", "dump", f"/dev/{dev}"])
    return rc == 0 and "magic: GEOM::ELI" in out


def _freebsd_parts(runner: Runner, parts: List[dict], pools: Dict[str, str]) -> None:
    """The file system, the pool and GELI of each partition."""
    for p in parts:
        rc, out = runner.run(f"fstyp_{p['dev']}", ["fstyp", f"/dev/{p['dev']}"])
        p["fs"] = fstyp_name(rc, out)
        if p["dev"] in pools:
            p["pool"] = pools[p["dev"]]
        if not p["fs"] and p["type"] not in ("efi", "msr", "freebsd-boot", "bios-boot") \
                and _is_geli(runner, p["dev"]):
            p["geli"] = True


def _zdb_pool(runner: Runner, name: str) -> Optional[str]:
    """The pool on a raw disk by its labels (zdb -l), or None."""
    rc, out = runner.run(f"zdb_-l_{name}", ["zdb", "-l", f"/dev/{name}"])
    m = re.search(r"^\s+name: '([^']+)'", out, re.M) if rc == 0 else None
    return m.group(1) if m else None


def _freebsd_whole(runner: Runner, disk: dict, name: str, pools: Dict[str, str]) -> None:
    """What a disk without partitions holds."""
    rc, out = runner.run(f"fstyp_whole_{name}", ["fstyp", f"/dev/{name}"])
    disk["whole_fs"] = fstyp_name(rc, out)
    # A pool on the raw disk: fstyp does not know it, zdb -l reads its
    # labels (and zpool import lists it when it is exported).
    if not disk["whole_fs"] and name not in pools:
        pool = _zdb_pool(runner, name)
        if pool:
            disk["pool"] = pool


def probe_freebsd(runner: Runner, names: List[str]) -> List[dict]:
    rc, out = runner.run("zpool_import", ["zpool", "import"])
    pools = freebsd_zpool_import(out) if rc == 0 else {}
    disks = []
    for name in names:
        disk = _freebsd_disk(name, _diskinfo(runner, name))
        rc, out = runner.run(f"gpart_list_{name}", ["gpart", "list", name])
        scheme, parts = freebsd_gpart_list(out, disk["sector"]) if rc == 0 else ("", [])
        disk["scheme"] = scheme or "none"
        _freebsd_parts(runner, parts, pools)
        if not parts:
            _freebsd_whole(runner, disk, name, pools)
        if name in pools:
            disk["pool"] = pools[name]
        disk["parts"] = parts
        disks.append(disk)
    return disks


def bus_of(name: str, attachment: str = "") -> str:
    probe = (attachment or name).lower()
    for prefix, bus in (("vtblk", "VirtIO"), ("vtbd", "VirtIO"), ("vbd", "VirtIO"),
                        ("nvd", "NVMe"), ("nda", "NVMe"), ("nvme", "NVMe"), ("ada", "SATA"),
                        ("ahci", "SATA"), ("wd", "SATA"), ("umass", "USB"),
                        ("mmcsd", "SD card"), ("sdmmc", "SD card"), ("ld", "")):
        if probe.startswith(prefix):
            return bus
    return ""


# ------------------------------------------------------------------- NetBSD


# A row of `gpt show -a`: start, size and the index (empty for a gap); its
# contents are the rest of the line.
GPT_SHOW_ROW_RE = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d*)")


def gpt_show_row(raw: str) -> Optional[Tuple[int, int, str, str]]:
    """(start, size, index, contents) of a row of `gpt show -a`, or None
    for a line that is not one (a key of the row before it)."""
    m = GPT_SHOW_ROW_RE.match(raw)
    if not m or raw.startswith(" " * 20):
        return None
    return int(m.group(1)), int(m.group(2)), m.group(3), raw[m.end():].strip()


def _gpt_show_entry(start: int, size: int, index: str,
                    contents: str) -> Tuple[Optional[dict], Optional[str]]:
    """The partition of a row of `gpt show -a` (None for a gap or a
    table), and "GPT" when the row is a GPT partition."""
    if contents.startswith("GPT part"):
        return {"start": start, "sectors": size, "index": index}, "GPT"
    if contents.startswith("MBR part"):
        mm = re.match(r"MBR part (\d+)", contents)
        return {"start": start, "sectors": size, "index": index,
                "mbr": int(mm.group(1)) if mm else None}, None
    return None, None


def _gpt_show_key(current: dict, raw: str) -> None:
    """A key of a partition of `gpt show -a`: its type and its label."""
    line = raw.strip()
    if line.startswith("TypeID:"):
        current["guid"] = line.split(":", 1)[1].strip()
    elif line.startswith("Label:"):
        current["label"] = line.split(":", 1)[1].strip()


def gpt_show_a(text: str, sector: int) -> Tuple[str, List[dict], int]:
    """scheme, partitions and size in sectors of NetBSD `gpt show -a`."""
    scheme = "none"
    parts = []
    total = 0
    current: Optional[dict] = None
    if "GPT not found" in text:
        scheme = "MBR" if re.search(r"^\s+\d+\s+\d+\s+\d+\s+MBR part", text, re.M) else "none"
    for raw in text.split("\n"):
        row = gpt_show_row(raw)
        if row:
            start, size, index, contents = row
            total = max(total, start + size)
            current, found = _gpt_show_entry(start, size, index, contents)
            if found:
                scheme = found
            if current is not None:
                parts.append(current)
            continue
        if current is not None:
            _gpt_show_key(current, raw)
    return scheme, _gpt_show_parts(parts, scheme, sector), total


def _gpt_show_parts(parts: List[dict], scheme: str, sector: int) -> List[dict]:
    """The partitions of the rows of `gpt show -a`: by their GPT type in a
    GPT, by their MBR id otherwise."""
    out = []
    for p in parts:
        guid = p.get("guid") if scheme == "GPT" else None
        out.append(part("", p["start"], p["sectors"], sector, guid=guid,
                        mbr=p.get("mbr") if scheme != "GPT" else None, label=p.get("label", "")))
    return out


# A wedge of `dkctl DISK listwedges`: "dkN: NAME, N blocks at N, type: TYPE".
WEDGE_HEAD_RE = re.compile(r"(dk\d+): ")
WEDGE_TAIL_RE = re.compile(r", (\d+) blocks at (\d+), type:")


def netbsd_wedge(line: str) -> Optional[Tuple[str, str, int, str]]:
    """(wedge, name, start, type) of a line of `dkctl DISK listwedges`, or
    None.  The name runs to the last ", N blocks at N, type:" (a name may
    hold one): two of those never overlap, so the last one found is it."""
    head = WEDGE_HEAD_RE.match(line)
    if not head:
        return None
    tails = list(WEDGE_TAIL_RE.finditer(line, head.end()))
    if not tails:
        return None
    tail = tails[-1]
    return head.group(1), line[head.end():tail.start()], int(tail.group(2)), line[tail.end():].strip()


def netbsd_wedges(text: str) -> List[Tuple[str, str, int, str]]:
    """(wedge, name, start, type) of `dkctl DISK listwedges`."""
    out = []
    for raw in text.split("\n"):
        wedge = netbsd_wedge(raw.strip())
        if wedge:
            out.append(wedge)
    return out


def netbsd_raid(text: str) -> Tuple[List[str], str]:
    """The component devices and the RAID level of `raidctl -s raidN`."""
    comps = re.findall(r"^\s+/dev/(\S+): \w+", text, re.M)
    level = re.search(r"RAID Level: (\S+)", text)
    return comps, (level.group(1) if level else "")


def _netbsd_raids(runner: Runner) -> List[str]:
    """The RAIDframe arrays of hw.disknames (raidN)."""
    rc, out = runner.run(HW_DISKNAMES_KEY, ["sysctl", "-n", HW_DISKNAMES])
    all_names = out.split() if rc == 0 else []
    return [n for n in all_names if re.fullmatch(r"raid\d+", n)]


def _netbsd_wedge_devs(runner: Runner, name: str, parts: List[dict],
                       wedge_of: Dict[str, Tuple[str, int]]) -> None:
    """The wedge of each partition, by its start: the dkN numbers change
    from one boot to the next."""
    rc, out = runner.run(f"dkctl_listwedges_{name}", ["dkctl", name, "listwedges"])
    wedges = netbsd_wedges(out) if rc == 0 else []
    for wedge, _wname, start, _wtype in wedges:
        wedge_of[wedge] = (name, start)
        for p in parts:
            if p["start"] == start:
                p["dev"] = wedge


def _netbsd_part_fstyp(runner: Runner, name: str, scheme: str, index: int,
                       p: dict) -> Tuple[int, str]:
    """fstyp of a partition of a NetBSD disk: through its wedge, or the
    disklabel partition of an MBR partition."""
    if p["dev"]:
        return runner.run(f"fstyp_{p['dev']}_{name}", ["fstyp", f"/dev/r{p['dev']}"])
    if scheme == "MBR":
        # Without wedges the partitions of an MBR are the disklabel
        # partitions e, f, ... of the fictitious label, in order.
        p["dev"] = f"{name}{chr(ord('e') + index)}"
        return runner.run(f"fstyp_{p['dev']}", ["fstyp", f"/dev/r{p['dev']}"])
    return 1, ""


def _netbsd_disk(runner: Runner, name: str, raids: List[str],
                 wedge_of: Dict[str, Tuple[str, int]]) -> dict:
    sector = 512
    rc, out = runner.run(f"gpt_show_-a_{name}", ["gpt", "show", "-a", name])
    scheme, parts, total = gpt_show_a(out, sector) if rc == 0 else ("none", [], 0)
    rc, fd = runner.run(f"fdisk_{name}", ["fdisk", name])
    m = re.search(r"total sectors: (\d+), bytes/sector: (\d+)", fd)
    if m:
        total, sector = int(m.group(1)), int(m.group(2))
        for p in parts:
            p["sector"] = sector
    disk = {"name": name, "size_bytes": total * sector, "sector": sector, "model": "",
            "serial": "", "bus": "", "ssd": None, "scheme": scheme}
    _netbsd_wedge_devs(runner, name, parts, wedge_of)
    for index, p in enumerate(parts):
        rc, out = _netbsd_part_fstyp(runner, name, scheme, index, p)
        p["fs"] = fstyp_name(rc, out)
    if not parts:
        rc, out = runner.run(f"fstyp_{name}a", ["fstyp", f"/dev/r{name}a"])
        disk["whole_fs"] = fstyp_name(rc, out)
    disk["parts"] = parts
    if name in raids:
        rc, out = runner.run(f"raidctl_-s_{name}", ["raidctl", "-s", name])
        comps, level = netbsd_raid(out) if rc == 0 else ([], "")
        disk["assembled"] = {"kind": "RAIDframe", "level": f"RAID {level}" if level else "",
                             "members": comps}
    return disk


def _netbsd_members(disk: dict, disks: List[dict],
                    wedge_of: Dict[str, Tuple[str, int]]) -> List[str]:
    """The disks that hold the components of an assembled array, each
    marked a member of it."""
    array = disk["assembled"]
    member_of = f"{disk['name']} ({array['kind']} {array['level']})".replace(" )", ")")
    members = []
    for comp in array["members"]:
        parent = wedge_of.get(comp, (re.sub(r"[a-p]$", "", comp), 0))[0]
        members.append(parent)
        for other in disks:
            if other["name"] == parent:
                other["member_of"] = member_of
    return members


def probe_netbsd(runner: Runner, names: List[str]) -> List[dict]:
    raids = _netbsd_raids(runner)
    wedge_of: Dict[str, Tuple[str, int]] = {}
    disks = [_netbsd_disk(runner, name, raids, wedge_of)
             for name in sorted(set(names) | set(raids), key=lambda n: (n in raids, n))]
    # The members of an assembled array: the disk that holds the component.
    for disk in disks:
        if disk.get("assembled"):
            disk["assembled"]["members"] = _netbsd_members(disk, disks, wedge_of)
    return disks


# ------------------------------------------------------------------ OpenBSD


# A GPT row of OpenBSD fdisk: "N: NAME [ START: SIZE ]".
FDISK_GPT_HEAD_RE = re.compile(r"^\s*(\d+): ")
FDISK_GPT_RANGE_RE = re.compile(r"\[\s*(\d+):\s*(\d+) \]")


def openbsd_fdisk_gpt_row(raw: str) -> Optional[Tuple[str, int, int]]:
    """(name, start, size) of a GPT row of OpenBSD fdisk, or None.  The
    name is at least one character and runs to the first "[ START: SIZE ]"
    after it, without the blanks before that."""
    head = FDISK_GPT_HEAD_RE.match(raw)
    if not head:
        return None
    begin = head.end()
    span = FDISK_GPT_RANGE_RE.search(raw, begin + 1)
    if not span:
        return None
    end = max(begin + 1, begin + len(raw[begin:span.start()].rstrip()))
    return raw[begin:end], int(span.group(1)), int(span.group(2))


def openbsd_fdisk(text: str) -> Tuple[str, List[dict], int, int]:
    """scheme, partitions, size in sectors and the MBR signature of fdisk."""
    m = re.search(r"\[(\d+) Sectors\]", text)
    total = int(m.group(1)) if m else 0
    sig = re.search(r"Signature: 0x([0-9A-Fa-f]+)", text)
    signature = int(sig.group(1), 16) if sig else 0
    parts = []
    if "Usable LBA" in text:
        for raw in text.split("\n"):
            row = openbsd_fdisk_gpt_row(raw)
            if row:
                parts.append(part("", row[1], row[2], 512, name=row[0]))
        return "GPT", parts, total, signature
    for raw in text.split("\n"):
        mm = re.match(r"^[ *](\d): ([0-9A-Fa-f]{2}) .*\[\s*(\d+):\s*(\d+) \]", raw)
        if mm and int(mm.group(2), 16) != 0 and int(mm.group(4)) > 0:
            parts.append(part("", int(mm.group(3)), int(mm.group(4)), 512, mbr=int(mm.group(2), 16)))
    return ("MBR" if parts else "none"), parts, total, signature


def openbsd_disklabel(text: str) -> Tuple[List[Tuple[str, int, str]], int]:
    """(letter, offset, fstype) of `disklabel -h` and the bytes per sector."""
    sector = re.search(r"bytes/sector: (\d+)", text)
    out = []
    for raw in text.split("\n"):
        m = re.match(r"^\s+([a-p]):\s+\S+\s+(\d+)\s+(\S+)", raw)
        if m and m.group(1) != "c":
            out.append((m.group(1), int(m.group(2)), m.group(3)))
    return out, int(sector.group(1)) if sector else 512


def openbsd_softraid(text: str) -> Dict[str, dict]:
    """{volume: {"level", "members"}} of `bioctl softraid0`."""
    volumes = {}
    current = None
    for raw in text.split("\n"):
        m = re.match(r"^\S+\s+\d+\s+\S+\s+\d+\s+(sd\d+)\s+(\S+)", raw)
        if m:
            current = {"level": m.group(2), "members": []}
            volumes[m.group(1)] = current
            continue
        m = re.search(r"<(sd\d+)[a-p]>", raw)
        if m and current is not None:
            current["members"].append(m.group(1))
    return volumes


def _openbsd_present(runner: Runner) -> List[str]:
    """The disks of hw.disknames (sd0:duid,sd1:duid,...)."""
    rc, out = runner.run(HW_DISKNAMES_KEY, ["sysctl", "-n", HW_DISKNAMES])
    return [item.split(":")[0] for item in out.strip().split(",") if item] if rc == 0 else []


def _openbsd_model(runner: Runner, name: str) -> str:
    """The model of a disk, from the first line of `bioctl DISK`."""
    rc, bio = runner.run(f"bioctl_{name}", ["bioctl", name])
    mm = re.search(r"<([^>]*)>", bio.split("\n")[0]) if rc == 0 else None
    if not mm:
        return ""
    return " ".join(w.strip() for w in mm.group(1).split(",") if w.strip())


def _openbsd_label_part(p: dict, name: str, letters: List[Tuple[str, int, str]]) -> None:
    """The disklabel letter of a partition is its device; its fstype is
    only a hint (an NTFS partition is labelled MSDOS): the type in the
    partition table wins."""
    for letter, offset, fstype in letters:
        if offset != p["start"]:
            continue
        p["dev"] = f"{name}{letter}"
        if fstype not in ("unused", "MSDOS", "RAID") or p["type"] == "efi":
            p["fs"] = FS_NAMES.get(fstype.lower(), fstype)
        if fstype == "RAID":
            p["raid_chunk"] = True


def _openbsd_disk(runner: Runner, name: str, volumes: Dict[str, dict]) -> dict:
    rc, out = runner.run(f"fdisk_{name}", ["fdisk", name])
    scheme, parts, total, signature = openbsd_fdisk(out) if rc == 0 else ("none", [], 0, 0)
    rc, out = runner.run(f"disklabel_-h_{name}", ["disklabel", "-h", name])
    letters, sector = openbsd_disklabel(out) if rc == 0 else ([], 512)
    m = re.search(r"total sectors: (\d+)", out)
    if m:
        total = int(m.group(1))
    model = _openbsd_model(runner, name)
    disk = {"name": name, "size_bytes": total * sector, "sector": sector, "model": model,
            "serial": "", "bus": "", "ssd": None, "scheme": scheme, "parts": parts,
            "mbr_signature": signature}
    for p in parts:
        _openbsd_label_part(p, name, letters)
    if not parts:
        for _letter, _offset, fstype in letters:
            if fstype not in ("unused",):
                disk["whole_fs"] = FS_NAMES.get(fstype.lower(), fstype)
    if name in volumes:
        disk["assembled"] = {"kind": "softraid", "level": volumes[name]["level"],
                             "members": volumes[name]["members"]}
    return disk


def probe_openbsd(runner: Runner, names: List[str]) -> List[dict]:
    present = _openbsd_present(runner)
    rc, out = runner.run("bioctl_softraid0", ["bioctl", "softraid0"])
    volumes = openbsd_softraid(out) if rc == 0 else {}
    disks = [_openbsd_disk(runner, name, volumes)
             for name in sorted(set(names) | {v for v in volumes if v in present})]
    for vol, info in volumes.items():
        for disk in disks:
            if disk["name"] in info["members"]:
                disk["member_of"] = f"{vol} (softraid {info['level']})"
    return disks


# ---------------------------------------------------------------- DragonFly


# A row of DragonFly `gpt show`: start, size and index; its contents are
# the rest of the line.
DRAGONFLY_ROW_RE = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\S+)\s+")


def dragonfly_gpt_show(text: str, sector: int) -> Tuple[str, List[dict], int]:
    scheme = "none"
    parts = []
    total = 0
    for raw in text.split("\n"):
        m = DRAGONFLY_ROW_RE.match(raw)
        if not m:
            continue
        start, size, index, contents = int(m.group(1)), int(m.group(2)), m.group(3), raw[m.end():].strip()
        total = max(total, start + size)
        if contents.startswith("GPT part - "):
            scheme = "GPT"
            parts.append(part(f"s{index}", start, size, sector, name=contents[len("GPT part - "):]))
        elif contents.startswith("MBR part"):
            scheme = "MBR"
            mm = re.match(r"MBR part (\d+)", contents)
            # The slices of an MBR are s1 to s4.
            parts.append(part(f"s{int(index) + 1}", start, size, sector,
                              mbr=int(mm.group(1)) if mm else None))
    return scheme, parts, total


def probe_dragonfly(runner: Runner, names: List[str]) -> List[dict]:
    disks = []
    for name in names:
        rc, out = runner.run(f"gpt_show_{name}", ["gpt", "show", name])
        scheme, parts, total = dragonfly_gpt_show(out, 512) if rc == 0 else ("none", [], 0)
        for p in parts:
            p["dev"] = f"{name}{p['dev']}"
            rc, out = runner.run(f"fstyp_{p['dev']}", ["fstyp", f"/dev/{p['dev']}"])
            p["fs"] = fstyp_name(rc, out)
        disk = {"name": name, "size_bytes": total * 512, "sector": 512, "model": "",
                "serial": "", "bus": bus_of(name), "ssd": None, "scheme": scheme, "parts": parts}
        if not parts:
            rc, out = runner.run(f"fstyp_{name}s0", ["fstyp", f"/dev/{name}s0"])
            disk["whole_fs"] = fstyp_name(rc, out)
        disks.append(disk)
    return disks


# ------------------------------------------------------------------- report

SYSNAMES = {"freebsd": "freebsd", "netbsd": "netbsd", "openbsd": "openbsd",
            "dragonfly": "dragonfly"}

PROBES = {"freebsd": probe_freebsd, "netbsd": probe_netbsd, "openbsd": probe_openbsd,
          "dragonfly": probe_dragonfly}


def efi_systems(files: List[str]) -> List[Tuple[str, str]]:
    """The systems that boot from an EFI system partition, by its files."""
    found = []
    lower = {f.lower().replace("\\", "/") for f in files}
    if any(f.startswith("efi/microsoft/boot/bootmgfw.efi") for f in lower):
        found.append(("Windows", "Windows"))
    dirs = sorted({f.split("/")[1] for f in lower if f.startswith("efi/") and f.count("/") >= 1})
    for d in dirs:
        if d in EFI_SYSTEMS:
            found.append(EFI_SYSTEMS[d])
    return found


WINDOWS_BITLOCKER = "Windows (BitLocker, not readable)"
LINUX_LUKS_NOTE = "encrypted (LUKS)"
FREEBSD_GELI_NOTE = "encrypted (GELI)"

# The partition types that only tell which system is on the disk: the
# system, and its detail, by the start of the type.
SYSTEM_OF_TYPE = (("netbsd", ("NetBSD", "NetBSD")), ("dragonfly", ("DragonFly", "DragonFly")))
APPLE_TYPES = ("apple-apfs", "apple-hfs")


def add_system(systems: List[Tuple[str, str]], name: str, detail: str) -> None:
    """A system found on a disk, once; a more precise detail wins (Debian
    over Linux)."""
    for i, (n, d) in enumerate(systems):
        if n == name:
            if d == n and detail != n:
                systems[i] = (name, detail)
            return
    systems.append((name, detail))


def _windows_data(kind: str, what: str, fs: str, sig: str,
                  systems: List[Tuple[str, str]]) -> Tuple[str, str]:
    """(kind, label) of a basic data or NTFS partition."""
    if sig == "bitlocker":
        add_system(systems, "Windows", WINDOWS_BITLOCKER)
        return "windows", WINDOWS_BITLOCKER
    if fs == "NTFS":
        add_system(systems, "Windows", "Windows")
        return "windows", "Windows (NTFS)"
    if fs:
        return kind, f"Data ({fs})"
    return kind, what


def _linux_part(ptype: str, kind: str, what: str, fs: str, sig: str,
                systems: List[Tuple[str, str]], notes: List[str]) -> Tuple[str, str]:
    """(kind, label) of a Linux partition."""
    add_system(systems, "Linux", "Linux")
    if sig == "luks" or ptype == "linux-luks":
        notes.append(LINUX_LUKS_NOTE)
        return "encrypted", "Linux, encrypted (LUKS)"
    return kind, f"Linux ({fs})" if fs else what


def _freebsd_part(p: dict, kind: str, what: str, fs: str, sig: str,
                  systems: List[Tuple[str, str]], notes: List[str]) -> Tuple[str, str]:
    """(kind, label) of a FreeBSD partition."""
    label = what
    if sig == "geli":
        kind, label = "encrypted", "FreeBSD, encrypted (GELI)"
        notes.append(FREEBSD_GELI_NOTE)
    elif p.get("pool"):
        label = f"FreeBSD ZFS pool {p['pool']}"
    elif fs:
        label = f"{what} ({fs})"
    add_system(systems, "FreeBSD", "FreeBSD")
    return kind, label


def _openbsd_part(p: dict, kind: str, what: str,
                  systems: List[Tuple[str, str]]) -> Tuple[str, str]:
    """(kind, label) of an OpenBSD partition."""
    add_system(systems, "OpenBSD", "OpenBSD")
    if p.get("raid_chunk"):
        return "raid", "OpenBSD softraid chunk"
    return kind, what


def _other_system(ptype: str) -> Optional[Tuple[str, str]]:
    """The system a NetBSD, DragonFly or macOS partition tells, or None."""
    if ptype == "netbsd-raid":
        return ("NetBSD", "NetBSD RAIDframe member")
    for prefix, found in SYSTEM_OF_TYPE:
        if ptype.startswith(prefix):
            return found
    if ptype in APPLE_TYPES:
        return ("macOS", "macOS")
    return None


def _part_kind_label(p: dict, fs: str, sig: str, systems: List[Tuple[str, str]],
                     notes: List[str]) -> Tuple[str, str]:
    """(kind, label) of a partition, and the system it tells."""
    ptype, kind, what = p["type"], p["kind"], p["what"]
    if ptype == "basic-data" or (ptype == "other" and fs == "NTFS"):
        return _windows_data(kind, what, fs, sig, systems)
    if ptype == "windows-recovery":
        return kind, WINDOWS_RECOVERY
    if kind == "linux" or ptype == "linux-luks":
        return _linux_part(ptype, kind, what, fs, sig, systems, notes)
    if ptype.startswith("freebsd") and ptype not in ("freebsd-swap",):
        return _freebsd_part(p, kind, what, fs, sig, systems, notes)
    if ptype.startswith("openbsd"):
        return _openbsd_part(p, kind, what, systems)
    found = _other_system(ptype)
    if found:
        add_system(systems, *found)
    return kind, what


def _report_part(os_name: str, disk: dict, p: dict, sector: int, runner: Runner,
                 systems: List[Tuple[str, str]], notes: List[str]) -> dict:
    """The report of one partition; the systems it tells are added."""
    nbytes = p["sectors"] * sector
    fs = p.get("fs", "")
    sig = runner.sniff(disk["name"], p["start"] * sector, nbytes, p.get("dev", "")).get("signature", "")
    if p.get("geli"):
        sig = "geli"
    kind, label = _part_kind_label(p, fs, sig, systems, notes)
    if p["type"] == "efi":
        files = runner.esp_files(os_name, p["dev"], disk["name"], p["start"] * sector, nbytes)
        for name, detail in efi_systems(files or []):
            add_system(systems, name, detail)
    if sig in ("luks", "geli") and "encrypted" not in label:
        label += f", encrypted ({sig.upper()})"
    return {"kind": kind, "label": label, "type": p["type"], "fs": fs,
            "size_bytes": nbytes, "start": p["start"]}


def _final_systems(systems: List[Tuple[str, str]], notes: List[str], disk: dict) -> List[dict]:
    """The systems of a disk, encryption shown with the system it belongs
    to; the member of an array is not a system of a member disk."""
    final = []
    for name, detail in systems:
        if disk.get("member_of") and "member" in detail:
            continue
        if name == "FreeBSD" and FREEBSD_GELI_NOTE in notes:
            detail = f"{detail} (encrypted with GELI)"
        if name == "Linux" and LINUX_LUKS_NOTE in notes:
            detail = f"{detail} (encrypted with LUKS)"
        final.append({"name": name, "detail": detail})
    return final


def _whole_zfs(out: dict, partitions: List[dict], pool: Optional[str], size: int) -> None:
    out["os"].append({"name": "ZFS", "detail": f"ZFS pool {pool}" if pool else "a ZFS pool"})
    out["signature"] = "zfs"
    partitions.append({"kind": "data", "label": f"ZFS pool {pool}" if pool else "ZFS pool",
                       "type": "zfs", "fs": "ZFS", "size_bytes": size, "start": 0})


def _whole_encrypted(out: dict, partitions: List[dict], sig: str, size: int) -> None:
    what = {"luks": "LUKS", "bitlocker": "BitLocker", "geli": "GELI"}[sig]
    out["os"].append({"name": "Encrypted", "detail": f"an encrypted volume ({what}, not readable)"})
    out["signature"] = sig
    partitions.append({"kind": "encrypted", "label": f"Encrypted ({what})", "type": sig,
                       "fs": "", "size_bytes": size, "start": 0})


def _whole_disk(out: dict, partitions: List[dict], disk: dict, size: int, runner: Runner) -> None:
    """What a disk without partitions (and not an array) holds."""
    whole = disk.get("whole_fs", "")
    sniffed = runner.sniff(disk["name"], 0, size)
    sig = sniffed.get("signature", "")
    if disk.get("pool") or sig == "zfs":
        _whole_zfs(out, partitions, disk.get("pool"), size)
    elif sig in ("luks", "bitlocker", "geli"):
        _whole_encrypted(out, partitions, sig, size)
    elif whole:
        out["os"].append({"name": "File system", "detail": f"a {whole} file system"})
        out["signature"] = whole
    elif sniffed.get("empty") is not True:
        # No table and no file system, but not zeros either, or the
        # disk could not be read: never called empty.
        detail = ("data the installer cannot read" if sniffed
                  else "a disk the installer could not read")
        out["os"].append({"name": "Unknown data", "detail": detail})
        out["unknown_bytes"] = MiB


def report_disk(os_name: str, disk: dict, runner: Runner) -> dict:
    """The report of one disk, as the disk page reads it."""
    sector = disk.get("sector") or 512
    size = int(disk.get("size_bytes") or 0)
    systems: List[Tuple[str, str]] = []
    notes: List[str] = []
    partitions = [_report_part(os_name, disk, p, sector, runner, systems, notes)
                  for p in disk.get("parts", [])]
    # A basic data partition without a file system the tools could name (the
    # disklabel of OpenBSD calls NTFS MSDOS) on a disk that boots Windows is
    # the Windows partition.
    if any(n == "Windows" for n, _d in systems):
        for p in partitions:
            if p["type"] == "basic-data" and p["kind"] == "data" and not p["fs"]:
                p["kind"], p["label"] = "windows", "Windows"
    out = {"name": disk["name"], "model": disk.get("model", ""), "size_bytes": size,
           "serial": disk.get("serial", ""), "bus": disk.get("bus", ""), "ssd": disk.get("ssd"),
           "scheme": disk.get("scheme") or "none", "partitions": [],
           "os": _final_systems(systems, notes, disk), "free": []}
    if not partitions and not disk.get("assembled"):
        _whole_disk(out, partitions, disk, size, runner)
    out["partitions"] = [{k: v for k, v in p.items() if k != "start"} for p in partitions]
    if disk.get("member_of"):
        out["member_of"] = disk["member_of"]
        out["os"].insert(0, {"name": "RAID", "detail": f"a member of {disk['member_of']}"})
    if disk.get("assembled"):
        array = disk["assembled"]
        out["assembled"] = {"kind": array["kind"], "level": array["level"],
                            "members": array["members"]}
    out["free"] = free_space(disk, partitions, size, sector)
    return out


def free_space(disk: dict, partitions: List[dict], size: int, sector: int) -> List[dict]:
    """The free regions of at least 1 MiB, in MiB from the start."""
    if size <= 0:
        return []
    if not partitions:
        if disk.get("whole_fs") or disk.get("pool"):
            return []
        # A disk without a table: all of it can be used once it is erased,
        # but it is free space only when it is empty.
        return [{"start_mb": 1, "size_mb": max(size // MiB - 1, 0)}]
    first = MiB
    # The backup GPT at the end: 33 sectors.
    last = size - 33 * sector
    used = sorted((p["start"] * sector, p["start"] * sector + p["size_bytes"]) for p in partitions)
    free = []
    pos = first
    for start, end in used:
        if start - pos >= MiB:
            free.append((pos, start - pos))
        pos = max(pos, end)
    if last - pos >= MiB:
        free.append((pos, last - pos))
    return [{"start_mb": -(-s // MiB), "size_mb": n // MiB} for s, n in free if n // MiB >= 1]


def assembled(os_name: str, runner: Runner) -> List[str]:
    """The arrays the system assembled by itself from members on the disks:
    NetBSD RAIDframe raidN (in hw.disknames), OpenBSD softraid volumes (in
    bioctl softraid0).  They are never offered as a disk to install to."""
    if os_name == "netbsd":
        return _netbsd_raids(runner)
    if os_name == "openbsd":
        rc, out = runner.run("bioctl_softraid0", ["bioctl", "softraid0"])
        return sorted(openbsd_softraid(out)) if rc == 0 else []
    return []


def probe(os_name: str, names: List[str], runner: Optional[Runner] = None) -> dict:
    """The disk report of a system for the disks named."""
    if os_name not in PROBES:
        raise ValueError(f"no disk probe for {os_name}")
    if runner is None:
        # Not on that system (its tools are not there): nothing is read and
        # nothing is guessed.
        if os.uname().sysname.lower() != SYSNAMES.get(os_name):
            return {"disks": []}
        runner = System(os_name)
    raw = PROBES[os_name](runner, names)
    disks = [report_disk(os_name, d, runner) for d in raw]
    return {"disks": disks}


def _options(args: List[str]) -> Tuple[List[str], str, str]:
    """The arguments after the options, the replay directories and the
    sniffs file (both under --base when it is given)."""
    replay, sniff_file = "", ""
    base = ""
    while args and args[0] in ("--replay", "--sniffs", "--base") and len(args) >= 2:
        if args[0] == "--replay":
            replay = args[1]
        elif args[0] == "--base":
            base = args[1]
        else:
            sniff_file = args[1]
        args = args[2:]
    if base:
        replay = ":".join(os.path.join(base, d) for d in replay.split(":") if d)
        sniff_file = os.path.join(base, sniff_file) if sniff_file else ""
    return args, replay, sniff_file


def _replay_runner(replay: str, sniff_file: str) -> Optional[Runner]:
    """The replay of captured outputs, or None as root (refused)."""
    if os.geteuid() == 0:
        sys.stderr.write("diskprobe: a replay is never run as root\n")
        return None
    sniffs = {}
    if sniff_file:
        with open(sniff_file, encoding="utf-8") as stream:
            sniffs = json.load(stream)
    return Replay(replay, sniffs if isinstance(sniffs, dict) else {})


def _print_assembled(os_name: str, runner: Optional[Runner]) -> None:
    """--assembled SYSTEM: the arrays the system assembled, one a line
    (none when this is not that system)."""
    if runner is None:
        if os.uname().sysname.lower() != SYSNAMES.get(os_name):
            return
        runner = System(os_name)
    for name in assembled(os_name, runner):
        print(name)


def main(argv: List[str]) -> int:
    """diskprobe.py [--replay DIR [--sniffs FILE]] SYSTEM DISK...

    --replay reads captured outputs instead of running the tools (a
    rehearsal; never as root, see lib/adapter.sh), --sniffs a JSON file of
    what the signature read finds."""
    args, replay, sniff_file = _options(argv[1:])
    runner: Optional[Runner] = None
    if not args:
        sys.stderr.write("usage: diskprobe.py [--replay DIR [--sniffs FILE]] "
                         "freebsd|netbsd|openbsd|dragonfly DISK...\n")
        return 2
    if replay:
        runner = _replay_runner(replay, sniff_file)
        if runner is None:
            return 2
    if args[0] == "--assembled" and len(args) == 2:
        _print_assembled(args[1], runner)
        return 0
    names = [n for n in args[1:] if DISK_NAME_RE.fullmatch(n)]
    try:
        report = probe(args[0], names, runner)
    except ValueError as error:
        sys.stderr.write(f"diskprobe: {error}\n")
        return 2
    print(json.dumps(report, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

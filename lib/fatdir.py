# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The names in a FAT file system (FAT12, FAT16, FAT32), read in userland.

The disk probe runs as root and must tell which systems boot from an EFI
system partition without mounting it: a mount hands untrusted bytes to the
kernel's file system code.  This module reads only the boot sector, the
FAT and the directories, through a read(offset, length) function, and
returns the paths of the files and directories (long names when there are
some), to a fixed depth.

Everything read is untrusted: every number is checked against the size of
the partition, a cluster chain is followed at most as many steps as there
are clusters and never through a cluster twice, and the number of names
and of bytes read is bounded.  A broken file system gives what could be
read, or nothing, never an exception.
"""

from typing import Callable, List, Optional

Read = Callable[[int, int], bytes]

MAX_NAMES = 2000
MAX_DEPTH = 4
MAX_DIR_BYTES = 1024 * 1024
MAX_READ = 64 * 1024 * 1024


class FatError(ValueError):
    """Not a FAT file system this module reads."""


class Fat:
    def __init__(self, read: Read, size: int):
        self.read_raw = read
        self.size = size
        self.budget = MAX_READ
        boot = self.read(0, 512)
        if len(boot) < 512 or boot[510:512] != b"\x55\xaa":
            raise FatError("no boot sector signature")
        u16 = lambda o: int.from_bytes(boot[o:o + 2], "little")  # noqa: E731
        u32 = lambda o: int.from_bytes(boot[o:o + 4], "little")  # noqa: E731
        self.bps = u16(11)
        self.spc = boot[13]
        reserved = u16(14)
        fats = boot[16]
        root_entries = u16(17)
        total = u16(19) or u32(32)
        fat_size = u16(22) or u32(36)
        if self.bps not in (512, 1024, 2048, 4096) or self.spc not in (1, 2, 4, 8, 16, 32, 64, 128):
            raise FatError("not a FAT boot sector")
        if not reserved or not fats or fats > 4 or not fat_size or not total:
            raise FatError("not a FAT boot sector")
        if total * self.bps > size + self.bps:
            raise FatError("the file system is larger than its partition")
        self.fat_start = reserved * self.bps
        root_sectors = (root_entries * 32 + self.bps - 1) // self.bps
        self.root_start = self.fat_start + fats * fat_size * self.bps
        self.data_start = self.root_start + root_sectors * self.bps
        data_sectors = total - (reserved + fats * fat_size + root_sectors)
        if data_sectors <= 0:
            raise FatError("no data area")
        self.clusters = data_sectors // self.spc
        self.cluster_bytes = self.spc * self.bps
        if self.clusters < 4085:
            self.kind = 12
        elif self.clusters < 65525:
            self.kind = 16
        else:
            self.kind = 32
        self.fat_bytes = fat_size * self.bps
        self.root_entries = root_entries
        self.root_cluster = u32(44) if self.kind == 32 else 0
        self._fat: Optional[bytes] = None

    def read(self, offset: int, length: int) -> bytes:
        if offset < 0 or length < 0 or offset + length > self.size:
            raise FatError("a read outside the partition")
        self.budget -= length
        if self.budget < 0:
            raise FatError("too much to read")
        return self.read_raw(offset, length)

    def fat(self) -> bytes:
        if self._fat is None:
            need = {12: (self.clusters + 2) * 3 // 2 + 2, 16: (self.clusters + 2) * 2,
                    32: (self.clusters + 2) * 4}[self.kind]
            self._fat = self.read(self.fat_start, min(need, self.fat_bytes))
        return self._fat

    def next_cluster(self, cluster: int) -> int:
        fat = self.fat()
        if self.kind == 12:
            off = cluster + cluster // 2
            if off + 2 > len(fat):
                return -1
            value = int.from_bytes(fat[off:off + 2], "little")
            value = value >> 4 if cluster & 1 else value & 0xFFF
            return -1 if value >= 0xFF8 else value
        if self.kind == 16:
            off = cluster * 2
            if off + 2 > len(fat):
                return -1
            value = int.from_bytes(fat[off:off + 2], "little")
            return -1 if value >= 0xFFF8 else value
        off = cluster * 4
        if off + 4 > len(fat):
            return -1
        value = int.from_bytes(fat[off:off + 4], "little") & 0x0FFFFFFF
        return -1 if value >= 0x0FFFFFF8 else value

    def chain(self, first: int) -> bytes:
        """The bytes of a cluster chain, bounded."""
        data = bytearray()
        seen = set()
        cluster = first
        while 2 <= cluster < self.clusters + 2 and cluster not in seen:
            seen.add(cluster)
            data += self.read(self.data_start + (cluster - 2) * self.cluster_bytes, self.cluster_bytes)
            if len(data) >= MAX_DIR_BYTES:
                break
            cluster = self.next_cluster(cluster)
        return bytes(data)

    def root(self) -> bytes:
        if self.kind == 32:
            return self.chain(self.root_cluster)
        return self.read(self.root_start, min(self.root_entries * 32, MAX_DIR_BYTES))


def lfn_part(entry: bytes) -> str:
    raw = entry[1:11] + entry[14:26] + entry[28:32]
    text = raw.decode("utf-16-le", "replace")
    return text.split("\x00")[0].replace("￿", "")


def entries(data: bytes):
    """(name, is_directory, first cluster) of a directory's bytes."""
    lfn: List[str] = []
    for pos in range(0, len(data) - 31, 32):
        entry = data[pos:pos + 32]
        first = entry[0]
        if first == 0:
            return
        if first == 0xE5:
            lfn = []
            continue
        attr = entry[11]
        if attr == 0x0F:
            if first & 0x40:
                lfn = []
            lfn.insert(0, lfn_part(entry))
            continue
        if attr & 0x08:
            lfn = []
            continue
        base = entry[0:8].decode("latin-1").rstrip()
        ext = entry[8:11].decode("latin-1").rstrip()
        if first == 0x05:
            base = "\xe5" + base[1:]
        if entry[12] & 0x08:
            base = base.lower()
        if entry[12] & 0x10:
            ext = ext.lower()
        short = f"{base}.{ext}" if ext else base
        name = "".join(lfn) or short
        lfn = []
        if name in (".", "..") or not name or "/" in name or "\x00" in name:
            continue
        cluster = int.from_bytes(entry[26:28], "little") | (int.from_bytes(entry[20:22], "little") << 16)
        yield name, bool(attr & 0x10), cluster


def list_files(read: Read, size: int) -> Optional[List[str]]:
    """The paths in a FAT file system, or None when it is not one."""
    try:
        fs = Fat(read, size)
    except FatError:
        return None
    out: List[str] = []
    seen_dirs = set()

    def walk(data: bytes, prefix: str, depth: int):
        for name, is_dir, cluster in entries(data):
            if len(out) >= MAX_NAMES:
                return
            path = f"{prefix}{name}"
            out.append(path)
            if is_dir and depth + 1 < MAX_DEPTH and cluster >= 2 and cluster not in seen_dirs:
                seen_dirs.add(cluster)
                walk(fs.chain(cluster), path + "/", depth + 1)

    try:
        walk(fs.root(), "", 0)
    except FatError:
        pass
    return out

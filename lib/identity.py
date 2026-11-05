# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The identity of the image: the line in the lower left of the installer.

The build of an image writes /usr/local/share/<slug>/identity, KEY=value:

    PRODUCT=ExampleBSD
    VERSION=1.2
    BASE=FreeBSD 16.0
    VARIANT=cyberpunk
    ARCH=amd64
    BUILD=2026-11-01        (test builds only)

It is parsed, never sourced: unknown keys, quotes, $, backquotes, control
characters and long values are left out.  Without the file the line still
names the product, the BSD it runs on (uname) and the architecture, so a
picture of the installer always says which system it shows.
"""

import re
from typing import Dict

KEYS = ("PRODUCT", "VERSION", "BASE", "VARIANT", "ARCH", "BUILD")
BSD_NAMES = {"freebsd": "FreeBSD", "netbsd": "NetBSD", "openbsd": "OpenBSD",
             "dragonfly": "DragonFly", "illumos": "illumos"}
VALUE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._+:-]{0,47}")
# The dot that joins the parts of the line: the space before it does
# not break, so the line wraps between two parts and never in the dot.
SEPARATOR = "\u00a0\u00b7 "
MAX_BYTES = 4096


# The release each template targets: what a picture of the installer for
# that system shows (tools/render-screenshots.sh, --render).
RELEASE_BASES = {"freebsd": "FreeBSD 16.0", "netbsd": "NetBSD 11.0", "openbsd": "OpenBSD 8.0",
                 "dragonfly": "DragonFly 6.4", "illumos": "illumos"}


def for_os(ident: Dict[str, str], os_name: str) -> Dict[str, str]:
    """The identity a picture of the installer for os_name shows: a BASE
    that names another system (a sample identity file) is replaced by the
    release of os_name, so an OpenBSD picture never says FreeBSD."""
    want = RELEASE_BASES.get(os_name)
    if not want:
        return ident
    base = ident.get("BASE", "")
    if base.split(" ")[0].lower() == want.split(" ")[0].lower():
        return ident
    return dict(ident, BASE=want)


def path_for(slug: str) -> str:
    return f"/usr/local/share/{slug}/identity"


def load(path: str) -> Dict[str, str]:
    try:
        with open(path, "rb") as stream:
            data = stream.read(MAX_BYTES + 1)
    except OSError:
        return {}
    if len(data) > MAX_BYTES:
        return {}
    out: Dict[str, str] = {}
    for raw in data.decode("utf-8", "replace").split("\n"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in KEYS and VALUE_RE.fullmatch(value):
            out[key] = value
    return out


def detected_base(uname, os_name: str) -> str:
    """The base system the installer sees: uname -sr of a BSD; on another
    system (a test machine) the name of the system it is configured for."""
    sysname, release = uname[0], uname[1]
    if sysname.lower() in BSD_NAMES:
        return f"{sysname} {release}"
    return BSD_NAMES.get(os_name, os_name)


def line(ident: Dict[str, str], product: str, arch: str, base: str) -> str:
    """<Product> <version> · <base OS and version> · <variant> · <arch>
    (· build <date>).

    The space before the dot is a space that does not break: the line
    wraps between two parts, never in the middle of the dot that joins
    them.
    """
    head = " ".join(x for x in (ident.get("PRODUCT") or product, ident.get("VERSION", "")) if x)
    parts = [head, ident.get("BASE") or base]
    if ident.get("VARIANT"):
        parts.append(ident["VARIANT"])
    parts.append(ident.get("ARCH") or arch)
    if ident.get("BUILD"):
        parts.append(f"build {ident['BUILD']}")
    return SEPARATOR.join(p for p in parts if p)

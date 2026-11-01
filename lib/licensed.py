# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The optional software whose licence the user has to accept.

The template ships a catalogue, licensed-software.json, with the licence
texts next to it.  The page "Additional software" lists it; selecting an
item accepts its licence; nothing is accepted for the user.  The root
helper checks the accepted ids against the catalogue on the media and
writes the record the install command gets with -l.

Pure: the catalogue is read strictly and nothing else is touched.
"""

import hashlib
import json
import os
import re
from typing import List

ID_RE = re.compile(r"[a-z][a-z0-9-]{0,47}")
PATH_RE = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*")
FLAGS = ("non-commercial", "vendor-key", "download-after-install", "needs-network")
# Select all never ticks these: they need their own tick.
OWN_TICK = ("non-commercial", "vendor-key")
MAX_CATALOGUE = 256 * 1024
MAX_TEXT = 1024 * 1024
ITEM_KEYS = {"id", "name", "description", "size_bytes", "licence", "flags", "install"}


class CatalogueError(ValueError):
    """A catalogue or an answer that cannot be used."""


def _text(value, what, limit=400):
    if not isinstance(value, str) or not value or len(value) > limit or \
            any(ord(c) < 32 for c in value):
        raise CatalogueError(f"{what} is not a line of text")
    return value


def _path(base, rel, what):
    """A file under the directory of the catalogue, never outside it."""
    if not isinstance(rel, str) or not PATH_RE.fullmatch(rel) or \
            any(part in (".", "..") for part in rel.split("/")):
        raise CatalogueError(f"{what} is not a path inside the catalogue")
    path = os.path.join(base, rel)
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(base) + os.sep) or not os.path.isfile(real):
        raise CatalogueError(f"{what} is not there")
    if os.path.getsize(real) > MAX_TEXT:
        raise CatalogueError(f"{what} is too large")
    return real


def _install_ok(install) -> bool:
    """An install method of packages by name or of one fetch helper."""
    return bool(isinstance(install, dict) and len(install) == 1 and (
        (isinstance(install.get("packages"), list) and install["packages"] and
         all(isinstance(p, str) and ID_RE.fullmatch(p) for p in install["packages"])) or
        (isinstance(install.get("fetch"), str) and ID_RE.fullmatch(install["fetch"]))))


def _item(raw, seen: set, base: str) -> dict:
    """One item of the catalogue, checked; its id is added to seen."""
    if not isinstance(raw, dict) or set(raw) - ITEM_KEYS:
        raise CatalogueError("an item has keys the catalogue does not know")
    ident = raw.get("id")
    if not isinstance(ident, str) or not ID_RE.fullmatch(ident) or ident in seen:
        raise CatalogueError(f"the id {ident!r} cannot be used")
    seen.add(ident)
    size = raw.get("size_bytes", 0)
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise CatalogueError(f"{ident}: the size is not a number")
    lic = raw.get("licence")
    if not isinstance(lic, dict) or set(lic) - {"id", "title", "text"} or \
            not isinstance(lic.get("id"), str) or not ID_RE.fullmatch(lic["id"]):
        raise CatalogueError(f"{ident}: the licence is not {{id, title, text}}")
    flags = raw.get("flags", [])
    if not isinstance(flags, list) or any(f not in FLAGS for f in flags):
        raise CatalogueError(f"{ident}: a flag is not one of {', '.join(FLAGS)}")
    install = raw.get("install")
    if not _install_ok(install):
        raise CatalogueError(f"{ident}: the install method is not packages or a fetch helper")
    return {
        "id": ident, "name": _text(raw.get("name"), f"{ident}: the name", 80),
        "description": _text(raw.get("description"), f"{ident}: the description"),
        "size_bytes": size, "flags": list(flags), "install": install,
        "licence": {"id": lic["id"], "title": _text(lic.get("title"), f"{ident}: the licence title", 120),
                    "text": _path(base, lic.get("text"), f"{ident}: the licence text")},
    }


def load(path: str) -> dict:
    """The catalogue in a file, checked: version 1, items with an id of
    plain letters, text, a size, a licence with its text in a file next to
    the catalogue, known flags and an install method of packages or a fetch
    helper by name."""
    base = os.path.dirname(os.path.realpath(path))
    try:
        if os.path.getsize(path) > MAX_CATALOGUE:
            raise CatalogueError("the catalogue is too large")
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError) as error:
        raise CatalogueError(f"the catalogue cannot be read: {error}") from error
    if not isinstance(data, dict) or data.get("version") != 1 or \
            not isinstance(data.get("items"), list) or set(data) - {"version", "items", "notices"}:
        raise CatalogueError("the catalogue is not version 1 with items")
    items = []
    seen = set()
    for raw in data["items"]:
        items.append(_item(raw, seen, base))
    notices = data.get("notices")
    return {"items": items,
            "notices": _path(base, notices, "the open-source notices") if notices else ""}


def item(catalogue: dict, ident: str) -> dict:
    for entry in catalogue.get("items", []):
        if entry["id"] == ident:
            return entry
    raise CatalogueError(f"{ident} is not in the catalogue")


def licence_text(catalogue: dict, ident: str) -> str:
    with open(item(catalogue, ident)["licence"]["text"], encoding="utf-8") as stream:
        return stream.read()


def notices_text(catalogue: dict) -> str:
    if not catalogue.get("notices"):
        return ""
    with open(catalogue["notices"], encoding="utf-8") as stream:
        return stream.read()


def select_all(catalogue: dict) -> List[str]:
    """What Select all ticks: every item but the ones that need their own
    tick (non-commercial, a vendor key)."""
    return [i["id"] for i in catalogue.get("items", [])
            if not any(f in OWN_TICK for f in i["flags"])]


def select_all_state(catalogue: dict, selected: List[str]) -> str:
    """"none", "some" or "all" of the items Select all ticks."""
    group = select_all(catalogue)
    chosen = [i for i in group if i in selected]
    if not chosen:
        return "none"
    return "all" if len(chosen) == len(group) else "some"


def parse_answer(text: str) -> List[str]:
    """The answer ACCEPT_LICENSES: ids separated by commas."""
    if not text:
        return []
    ids = text.split(",")
    for ident in ids:
        if not ID_RE.fullmatch(ident):
            raise CatalogueError(f"{ident!r} is not an id of the catalogue")
    return ids


def check_accepted(catalogue: dict, ids: List[str]) -> List[str]:
    """The problems of a list of accepted ids: unknown or given twice."""
    errors = []
    known = {i["id"] for i in catalogue.get("items", [])}
    for ident in ids:
        if ident not in known:
            errors.append(f"{ident!r} is not in the catalogue on the media")
    if len(ids) != len(set(ids)):
        errors.append("an item is accepted twice")
    return errors


def record(catalogue: dict, ids: List[str], when: str) -> List[dict]:
    """What the install command gets with -l: every accepted item, its
    licence, the sha256 of the licence text the user could read, and when."""
    out = []
    for ident in ids:
        entry = item(catalogue, ident)
        with open(entry["licence"]["text"], "rb") as stream:
            digest = hashlib.sha256(stream.read()).hexdigest()
        out.append({"id": ident, "licence": entry["licence"]["id"], "sha256": digest,
                    "accepted_at": when})
    return out

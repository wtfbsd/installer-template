# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The look of the installer, from the artwork template of the product.

The artwork template (palette.env and the SVG sources in src/, with tokens
such as @PRIMARY@ and @NAME@) is installed next to the installer
(install-into-stage.sh --artwork DIR).  The installer reads it directly:
the colours make its style, the logo goes above the steps, the wallpapers
are the backgrounds of the slides shown while it installs.  The tokens are
substituted in memory, so no renderer is needed on the live system.

A template may bring its own slides: slides/slides.txt, one slide a line,
"title|text|image" (image: wallpaper-N or empty).  Without them the
installer shows its own, in the language of the installer.

Without artwork the installer keeps its built-in look.
"""

import os
import re
from typing import Dict, List, Optional, Tuple

import i18n

COLOURS = ("PRIMARY", "ACCENT", "DARK", "DARK2", "LIGHT", "MUTED")
TEXTS = ("NAME", "NAME_LOWER", "TAGLINE")
DEFAULT = {"NAME": "", "NAME_LOWER": "", "TAGLINE": "", "PRIMARY": "4C8BF5",
           "ACCENT": "26A269", "DARK": "1F2430", "DARK2": "262C3A", "LIGHT": "F7F7F7",
           "MUTED": "8A93B2"}
ASSETS = {"logo": "src/logo.svg", "wordmark-light": "src/wordmark-light.svg",
          "sidebar": "src/installer-sidebar.svg", "wallpaper-1": "src/wallpaper-1.svg",
          "wallpaper-2": "src/wallpaper-2.svg", "wallpaper-3": "src/wallpaper-3.svg"}
MAX_SVG = 2 * 1024 * 1024


class BrandingError(ValueError):
    """Artwork that cannot be used."""


def parse_palette(path: str) -> Dict[str, str]:
    """palette.env, parsed (never sourced): colours of six hex digits and
    short texts without quotes or control characters."""
    out = dict(DEFAULT)
    with open(path, encoding="utf-8") as stream:
        for number, raw in enumerate(stream, start=1):
            entry = _palette_line(number, raw.rstrip("\n"))
            if entry is not None:
                out[entry[0]] = entry[1]
    return out


def _palette_line(number: int, line: str) -> Optional[Tuple[str, str]]:
    """The key and the value of one line of palette.env, None for a blank
    line or a comment; BrandingError when it cannot be used."""
    if not line.strip() or line.lstrip().startswith("#"):
        return None
    key, sep, value = line.partition("=")
    if not sep or key not in COLOURS + TEXTS:
        raise BrandingError(f"palette.env line {number}: not a key of the palette")
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    if key in COLOURS:
        if not re.fullmatch(r"[0-9A-Fa-f]{6}", value):
            raise BrandingError(f"palette.env line {number}: {key} is not six hex digits")
    elif len(value) > 80 or any(c in value for c in '"\\$`') or \
            any(ord(c) < 32 for c in value):
        raise BrandingError(f"palette.env line {number}: {key} is not a short text")
    return key, value


def substitute(text: str, palette: Dict[str, str]) -> str:
    """The tokens of an SVG replaced; a text value escaped for XML."""
    def value(match):
        key = match.group(1)
        if key not in palette:
            return match.group(0)
        val = palette[key]
        if key in TEXTS:
            val = val.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        return val
    return re.sub(r"@([A-Z0-9_]+)@", value, text)


def luminance(hexcolour: str) -> float:
    """The relative luminance of a colour (WCAG 2)."""
    out = 0.0
    for weight, i in ((0.2126, 0), (0.7152, 2), (0.0722, 4)):
        c = int(hexcolour[i:i + 2], 16) / 255
        c = c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
        out += weight * c
    return out


def contrast(a: str, b: str) -> float:
    """The contrast ratio of two colours (WCAG 2), 1 to 21."""
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


class Branding:
    def __init__(self, directory: str, palette: Dict[str, str], variant: str = "default",
                 art: str = ""):
        self.directory = directory
        self.palette = palette
        self.variant = variant
        # The art of a variant (variants/<name>/src), else the template's.
        self.art = art

    def identity_colour(self) -> str:
        """The colour of the identity line: understated (MUTED) when it is
        readable on both ends of the sidebar, else the first of LIGHT and
        white that is (contrast at least 4.5:1)."""
        p = self.palette
        for colour in (p["MUTED"], p["LIGHT"], "FFFFFF"):
            if all(contrast(colour, p[bg]) >= 4.5 for bg in ("DARK", "DARK2")):
                return colour
        return "FFFFFF"

    def svg(self, name: str) -> Optional[bytes]:
        """An asset of the template, its tokens substituted, or None."""
        if not self.directory or name not in ASSETS:
            return None
        path = os.path.join(self.directory, ASSETS[name])
        if self.art and os.path.isfile(os.path.join(self.art, ASSETS[name])):
            path = os.path.join(self.art, ASSETS[name])
        if not os.path.isfile(path) or os.path.getsize(path) > MAX_SVG:
            return None
        with open(path, encoding="utf-8") as stream:
            return substitute(stream.read(), self.palette).encode("utf-8")

    def wallpapers(self) -> List[str]:
        return [n for n in ("wallpaper-1", "wallpaper-2", "wallpaper-3") if self.svg(n)]

    def css(self) -> str:
        p = self.palette
        return f"""
.sidebar {{ background-image: linear-gradient(to bottom, #{p['DARK2']}, #{p['DARK']});
            background-color: #{p['DARK']}; }}
.sidebar .step-current {{ border-left-color: #{p['ACCENT']}; }}
.sidebar .step-done {{ color: #{p['ACCENT']}; }}
.sidebar .tagline {{ color: #{self.identity_colour()}; font-size: 12px; }}
button.suggested-action {{ background-image: none; background-color: #{p['PRIMARY']};
                           color: #ffffff; border-color: #{p['PRIMARY']}; }}
.mode-card:checked, .layout-card:checked {{ border-color: #{p['PRIMARY']}; }}
progressbar progress {{ background-image: none; background-color: #{p['PRIMARY']};
                         border-color: #{p['PRIMARY']}; }}
.sidebar .identity {{ color: #{self.identity_colour()}; font-size: 11px; }}
.slide {{ background-color: #{p['DARK']}; }}
.slide-title {{ color: #ffffff; font-size: 26px; font-weight: bold; }}
.slide-text {{ color: #{p['LIGHT']}; font-size: 15px; }}
"""

    def slides(self, product: str, lang: str) -> List[dict]:
        """The slides shown while the system is installed."""
        own = os.path.join(self.directory, "slides", "slides.txt") if self.directory else ""
        if own and os.path.isfile(own):
            out = []
            with open(own, encoding="utf-8") as stream:
                for line in stream:
                    parts = line.rstrip("\n").split("|")
                    if len(parts) != 3 or not parts[0] or not parts[1]:
                        continue
                    image = parts[2] if parts[2] in ASSETS else None
                    out.append({"title": parts[0][:80], "text": parts[1][:400], "image": image})
            if out:
                return out
        walls = self.wallpapers() or [None]
        keys = ("welcome", "desktop", "software", "updates", "privacy", "help")
        return [{"title": i18n.t(f"slide.{k}.title", lang, product=product),
                 "text": i18n.t(f"slide.{k}.text", lang, product=product),
                 "image": walls[i % len(walls)]} for i, k in enumerate(keys)]


def load(directory: str, variant: str = "") -> Branding:
    """The branding of a directory of artwork, or the built-in look.  A
    variant (variants/<name>/palette.env, and its own art in
    variants/<name>/src) is used when the template has it; any other name
    is the default."""
    if not directory:
        return Branding("", dict(DEFAULT))
    palette_path = os.path.join(directory, "palette.env")
    if not os.path.isfile(palette_path):
        raise BrandingError(f"{directory} has no palette.env")
    if variant and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", variant) and variant != "default":
        vdir = os.path.join(directory, "variants", variant)
        vpal = os.path.join(vdir, "palette.env")
        if os.path.isfile(vpal):
            return Branding(directory, parse_palette(vpal), variant, vdir)
    return Branding(directory, parse_palette(palette_path))

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# tools/render-flags.sh FLAG_ICONS_DIR
#
# Renders the flags of the language picker into gui/flags: <cc>.png
# (24x18) and <cc>-2x.png (48x36) for every region of the language table
# of lib/i18n.py, from the 4x3 SVGs of flag-icons (MIT, see THIRD-PARTY;
# a checkout of https://github.com/lipis/flag-icons).  PNG and not SVG: the
# PNG loader is part of GdkPixbuf everywhere, the SVG loader (librsvg) is
# not on every live image.  Needs python3 with PyGObject and librsvg where
# it runs, not on the live system.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
src=${1:?usage: tools/render-flags.sh FLAG_ICONS_DIR}
[ -d "${src}/flags/4x3" ] || { printf 'render-flags: no flags/4x3 in %s\n' "${src}" >&2; exit 1; }
mkdir -p "${root}/gui/flags"
python3 -I - "${root}" "${src}/flags/4x3" <<'PY'
import os
import sys

import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf

root, svgs = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "lib"))
import i18n

regions = sorted({c for _l, _o, _e, variants in i18n.LANGUAGES for _loc, c, _r in variants})
for cc in regions:
    svg = os.path.join(svgs, cc.lower() + ".svg")
    for scale, suffix in ((1, ""), (2, "-2x")):
        pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(svg, 24 * scale, 18 * scale, False)
        out = os.path.join(root, "gui", "flags", f"{cc.lower()}{suffix}.png")
        pix.savev(out, "png", ["compression"], ["9"])
    print(cc.lower())
PY

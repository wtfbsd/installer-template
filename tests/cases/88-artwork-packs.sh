#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The artwork packs of the artwork template install: their palette.env has
# HIGHLIGHT, IDENTITY_FG and FONT, a variant names itself (VARIANT_LABEL)
# and sets only the keys it changes.  The new keys are used (focus accent,
# identity line, font of the window); a key the palette does not know is
# still refused, so a typo is caught.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-packs.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

mkdir "${tmp}/stage-default" "${tmp}/stage-cyberpunk" "${tmp}/stage-typo" "${tmp}/stage-badhl"
for pack in default cyberpunk; do
	rc=0
	out=$("${root}/install-into-stage.sh" "${tmp}/stage-${pack}" --artwork "tests/fixtures/packs/${pack}" \
		--metalog "${tmp}/METALOG-${pack}" 2>&1) || rc=$?
	check "the ${pack} pack installs" 0 "${rc}"
	[ "${rc}" = 0 ] || printf '%s\n' "${out}" >&2
	check "the ${pack} pack: its palette is staged" yes \
		"$([ -f "${tmp}/stage-${pack}/usr/local/libexec/wtfbsd-installer/artwork/palette.env" ] && echo yes || echo no)"
done

b() { # b <pack> <variant> <python expression of the branding b>
	python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import branding
b = branding.load(sys.argv[2], sys.argv[3]); print(eval(sys.argv[4]))' \
		"${root}/lib" "tests/fixtures/packs/$1" "$2" "$3" 2>&1
}
check "default: the identity line is IDENTITY_FG" A3ABC8 "$(b default '' 'b.identity_colour()')"
check "default: HIGHLIGHT is the focus accent" yes \
	"$(b default '' '"yes" if "inset 0 0 0 2px #F2B33D, 0 0 0 2px #14182B" in b.css() else b.css()')"
check "default: FONT is the font of the window" yes \
	"$(b default '' '"yes" if "font-family: \"DejaVu Sans\"" in b.css() else b.css()')"
check "cyberpunk: the variant overrides the keys it sets" "FF2BD6 00E5F2 DejaVu Sans Mono" \
	"$(b cyberpunk cyberpunk 'b.palette["PRIMARY"] + " " + b.identity_colour() + " " + b.palette["FONT"]')"
check "cyberpunk: the keys it does not set come from palette.env" "ExampleBSD Cyberpunk" \
	"$(b cyberpunk cyberpunk 'b.palette["NAME"] + " " + b.palette["VARIANT_LABEL"]')"

# A typo is refused, a colour that is not one too.
mkdir -p "${tmp}/typo" "${tmp}/badhl"
cp tests/fixtures/packs/default/palette.env "${tmp}/typo/palette.env"
printf 'HILIGHT=F2B33D\n' >> "${tmp}/typo/palette.env"
cp tests/fixtures/packs/default/palette.env "${tmp}/badhl/palette.env"
printf 'IDENTITY_FG=#A3ABC8\n' >> "${tmp}/badhl/palette.env"
rc=0; "${root}/install-into-stage.sh" "${tmp}/stage-typo" --artwork "${tmp}/typo" \
	--metalog "${tmp}/METALOG-typo" >"${tmp}/typo.log" 2>&1 || rc=$?
check "an unknown key is still refused" "1 yes" \
	"$([ "${rc}" = 0 ] && echo 0 || echo 1) $(grep -q 'not a key of the palette' "${tmp}/typo.log" && echo yes || echo no)"
rc=0; "${root}/install-into-stage.sh" "${tmp}/stage-badhl" --artwork "${tmp}/badhl" \
	--metalog "${tmp}/METALOG-badhl" >"${tmp}/badhl.log" 2>&1 || rc=$?
check "IDENTITY_FG gets the check of a colour" "1 yes" \
	"$([ "${rc}" = 0 ] && echo 0 || echo 1) $(grep -q 'IDENTITY_FG is not six hex digits' "${tmp}/badhl.log" && echo yes || echo no)"

finish

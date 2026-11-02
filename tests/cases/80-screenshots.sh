#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The pictures of the documentation: README.md has a section "What it looks
# like", gui/README.md shows every page, every image either file links to
# exists, docs/screenshots holds exactly the pictures tools/shots/docs*.json
# names (small PNGs), and tools/render-screenshots.sh renders them headless.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-screenshots.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

check_contains "the README has the section" "## What it looks like" "$(cat README.md)"
# The pictures say which BSD they show, and so do their captions.
section=$(sed -n '/^## What it looks like/,/^## /p' README.md)
check_contains "the README captions name the BSD of the pictures" "FreeBSD 16.0" "${section}"
check_contains "gui/README.md names the BSD of the pictures" "FreeBSD 16.0" "$(cat gui/README.md)"
check_contains "the cyberpunk variant is shown" "12-welcome-cyberpunk.png" "$(cat README.md)"

# links <markdown file> — the targets of its image links, one a line.
links() {
	grep -o '!\[[^]]*\]([^)]*)' "$1" | sed 's/.*](\(.*\))$/\1/'
}
for doc in README.md gui/README.md; do
	n=$(links "${doc}" | wc -l | tr -d ' ')
	[ "${n}" -ge 5 ] && enough=yes || enough=no
	check "${doc} shows pictures (${n})" yes "${enough}"
	dir=$(dirname "${doc}")
	missing=''
	for target in $(links "${doc}"); do
		[ -f "${dir}/${target}" ] || missing="${missing} ${target}"
	done
	check "every picture of ${doc} exists" "" "${missing}"
done

# The names the specs give, against the files of docs/screenshots.
names=$(python3 -I -c '
import json, sys
for path in sys.argv[1:]:
    for shot in json.load(open(path, encoding="utf-8")):
        print(shot["name"] + ".png")
' tools/shots/docs.json tools/shots/docs-large.json tools/shots/docs-variant.json | sort)
files=$(ls docs/screenshots 2>/dev/null | sort)
check "docs/screenshots holds exactly the rendered pictures" "${names}" "${files}"
big=''
for png in docs/screenshots/*.png; do
	[ -f "${png}" ] || continue
	[ "$(wc -c < "${png}")" -le 307200 ] || big="${big} ${png}"
done
check "every picture is at most 300 KB" "" "${big}"
for page in welcome keyboard timezone installation-type disk users network \
	additional-software summary installing hardware-and-drivers finished; do
	check_contains "gui/README.md shows the page ${page}" "-${page}.png" "$(cat gui/README.md)"
done

if command -v broadwayd >/dev/null 2>&1 && python3 -I -c 'import gi' 2>/dev/null; then
	sh tools/render-screenshots.sh "${tmp}/out" > "${tmp}/render.log" 2>&1 && rc=0 || rc=$?
	check_rc "the render script runs headless" 0 "${rc}"
	check "it renders every picture" "${names}" "$(ls "${tmp}/out" | sort)"
	sizes=$(python3 -I -c '
import struct, sys
for path in sys.argv[1:]:
    with open(path, "rb") as stream:
        head = stream.read(24)
    print(path.rsplit("/", 1)[1], *struct.unpack(">II", head[16:24]))
' "${tmp}/out/01-welcome.png" "${tmp}/out/large-welcome.png")
	check "the sizes of the pictures" "01-welcome.png 1024 768
large-welcome.png 1920 1080" "${sizes}"
else
	printf 'skip the render: no broadwayd or PyGObject\n'
fi

finish

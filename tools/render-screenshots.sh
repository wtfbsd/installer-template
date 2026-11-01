#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# tools/render-screenshots.sh [OUTDIR]
#
# Renders the pictures of the graphical installer that the documentation
# shows (docs/screenshots by default), headless: GTK draws on its Broadway
# backend (broadwayd), no X server and no screen are needed.  The pages are
# filled from the test fixtures (sample data: made-up disks, documentation
# addresses, the placeholder product ExampleBSD of the artwork template),
# never from the machine it runs on.
#
#   tools/shots/docs.json          every page, 1024x768, NN-<page>.png
#   tools/shots/docs-large.json    a few pages, 1920x1080, large-<page>.png
#   tools/shots/docs-variant.json  the cyberpunk variant of the artwork
#
# Every picture carries the identity line in its lower left (product,
# version, the BSD it shows, variant, architecture), from
# tests/fixtures/identity-default (the cyberpunk ones tests/fixtures/identity).
# The BSD is the one of the configuration the pictures are drawn for
# (INSTALLER_CONF, else installer.conf: OS=openbsd shows OpenBSD 8.0), the
# release of its template (RELEASE_BASES of lib/identity.py), whatever BASE
# the sample identity file names.
#
# The PNGs are made smaller with optipng, oxipng or pngcrush when one of
# them is installed.  Needs python3 with PyGObject (GTK 3) and broadwayd.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
out=${1:-${root}/docs/screenshots}

die() {
	printf 'render-screenshots: %s\n' "$*" >&2
	exit 1
}

command -v broadwayd >/dev/null 2>&1 || die 'broadwayd (GTK 3) is not installed'
python3 -I -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' \
	2>/dev/null || die 'python3 has no PyGObject with GTK 3'
mkdir -p "${out}"
out=$(CDPATH= cd "${out}" && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/render-screenshots.XXXXXX")
bpid=''
cleanup() {
	[ -z "${bpid}" ] || kill "${bpid}" 2>/dev/null || :
	rm -rf "${work}"
}
trap cleanup EXIT INT TERM HUP

# A display number another program uses makes broadwayd stop: try others.
ready=no
for try in 1 2 3 4 5 6 7 8; do
	n=$(( ( ($$ + try * 53) % 400) + 1000 ))
	broadwayd ":${n}" >/dev/null 2>&1 &
	bpid=$!
	for wait in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "${bpid}" 2>/dev/null || break
		if BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway "${root}/bin/installer-gui" --check \
			>/dev/null 2>&1; then
			ready=yes
			break
		fi
		sleep 0.5
	done
	[ "${ready}" = no ] || break
	kill "${bpid}" 2>/dev/null || :
	bpid=''
done
[ "${ready}" = yes ] || die 'broadwayd did not start'

# render <spec> <size> <identity file>
render() {
	shots="${work}/shots"
	rm -rf "${shots}" && mkdir "${shots}"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${work}" \
		INSTALLER_ARTWORK="${root}/tests/fixtures/artwork" INSTALLER_IDENTITY="$3" \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
		"${root}/bin/installer-gui" --render "$1" --size "$2" --screenshots "${shots}" \
		> "${work}/render.log" 2>&1 || { cat "${work}/render.log" >&2; die "cannot render $1"; }
	for png in "${shots}"/*.png; do
		[ -f "${png}" ] || continue
		cp "${png}" "${out}/${png##*/}"
		printf '%s\n' "${png##*/}"
	done
}

render "${root}/tools/shots/docs.json" 1024x768 "${root}/tests/fixtures/identity-default"
render "${root}/tools/shots/docs-large.json" 1920x1080 "${root}/tests/fixtures/identity-default"
render "${root}/tools/shots/docs-variant.json" 1024x768 "${root}/tests/fixtures/identity"

for png in "${out}"/*.png; do
	if command -v optipng >/dev/null 2>&1; then
		optipng -quiet -o2 "${png}" || :
	elif command -v oxipng >/dev/null 2>&1; then
		oxipng -q -o 2 "${png}" || :
	elif command -v pngcrush >/dev/null 2>&1; then
		pngcrush -q -ow "${png}" || :
	fi
done

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Hardware and drivers: the root helper lists the parts of the machine, the
# driver of each and whether its firmware is on the media (read only, a
# rehearsal reads the fixture).  Branding: the installer takes its colours,
# logo and slides from the artwork template next to it, and an unusable
# palette never breaks it.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-hardware.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf"
export INSTALLER_ADAPTER_FIXTURE

out=$(bin/installer-apply --list hardware 2>&1) && rc=0 || rc=$?
check_rc "the helper lists the hardware" 0 "${rc}"
check_contains "a part with its driver" '"class":"Wi-Fi","name":"Example Wireless AC 9260","driver":"iwm"' "${out}"
check_contains "a part without firmware" '"firmware":"missing","status":"no driver"' "${out}"

# A device name that is not printable text is cleaned, not passed on.
printf '{"devices":[{"class":"GPU","name":"A\\u001b[31mB","driver":"x"}, 5]}\n' > "${tmp}/hw.json"
sed "s|^HARDWARE=.*|HARDWARE=${tmp}/hw.json|" "${INSTALLER_ADAPTER_FIXTURE}" | \
	sed "s|^\([A-Z_]*\)=\.\./|\1=${root}/tests/fixtures/|; s|^\([A-Z_]*\)=\([a-z-]*\.json\)$|\1=${root}/tests/fixtures/disks/\2|" \
	> "${tmp}/fixture.conf"
out=$(INSTALLER_ADAPTER_FIXTURE="${tmp}/fixture.conf" bin/installer-apply --list hardware 2>&1) || :
check_contains "control characters are dropped" '"name":"A[31mB"' "${out}"

# The real tools of FreeBSD, captured on a virtual machine and replayed
# through the root helper (HARDWARE_CAPTURE): what the system did not have
# is "not available", never an error.
out=$(INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/captured-freebsd.conf" \
	bin/installer-apply --list hardware 2>&1) && rc=0 || rc=$?
check_rc "the captured hardware is read" 0 "${rc}"
check_contains "the display without a DRM driver" '"driver":"vgapci0","firmware":"not needed","status":"basic display (no DRM driver)"' "${out}"
check_contains "the missing firmware directory is not available" '"unavailable":["the firmware directory /usr/local/share/firmware"]' "${out}"

ready=no
if command -v broadwayd >/dev/null 2>&1 && python3 -I -B -c 'import gi' 2>/dev/null; then
	# A display number another program uses makes broadwayd stop: try the next.
	for try in 1 2 3 4 5 6; do
		n=$(( ( ($$ + try * 41) % 400) + 520 ))
		broadwayd ":${n}" >/dev/null 2>&1 &
		bpid=$!
		for wait in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "${bpid}" 2>/dev/null || break
			if BROADWAY_DISPLAY=":${n}" GDK_BACKEND=broadway bin/installer-gui --check >/dev/null 2>&1; then
				ready=yes
				break
			fi
			sleep 0.5
		done
		[ "${ready}" = no ] || break
		kill "${bpid}" 2>/dev/null || :
	done
fi
render() { # render <artwork dir> <shots dir>
	rm -rf "$2" && mkdir "$2"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ARTWORK="$1" \
		bin/installer-gui --render tools/shots/brand.json --size 1024x768 --screenshots "$2" \
		> "${tmp}/render.log" 2>&1
}
if [ "${ready}" = yes ]; then
	trap 'kill "${bpid}" 2>/dev/null; rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP
	render "${root}/tests/fixtures/artwork" "${tmp}/shots" && rc=0 || rc=$?
	check_rc "the branded pages render" 0 "${rc}"
	for name in brand-welcome hardware-drivers installing-slide-1 installing-slide-german; do
		[ -s "${tmp}/shots/${name}.png" ] && got=yes || got=no
		check "${name} was rendered" yes "${got}"
	done
	# The button with the focus shows it (a ring of its own, also where the
	# toolkit never reports keyboard use): the action cluster differs with
	# the focus on one button or on the other.
	same=$(python3 -I -B -c '
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
a, b = (GdkPixbuf.Pixbuf.new_from_file(p) for p in sys.argv[1:3])
h = a.get_height()
crop = lambda p: p.new_subpixbuf(0, h - 70, p.get_width(), 70).get_pixels()
print("same" if crop(a) == crop(b) else "differ")' "${tmp}/shots/focus-try-live.png" "${tmp}/shots/focus-install.png")
	check "the focus is visible on the buttons of the action cluster" differ "${same}"
	# The identity line in the lower left: there with the identity file of
	# the image, readable (4.5:1) on the default palette and on the
	# cyberpunk variant the identity names.
	printf '[{"name": "identity", "page": "welcome", "full": false, "state": {"locale": "en_US.UTF-8"}}]\n' \
		> "${tmp}/identity.json"
	ident() { # ident <identity file> <shots dir>
		rm -rf "$2" && mkdir "$2"
		GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
			INSTALLER_ARTWORK="${root}/tests/fixtures/artwork" INSTALLER_IDENTITY="$1" \
			bin/installer-gui --render "${tmp}/identity.json" --size 1024x768 --screenshots "$2" \
			> "${tmp}/render.log" 2>&1
	}
	sed 's/^VARIANT=.*/VARIANT=default/' "${root}/tests/fixtures/identity" > "${tmp}/identity-default"
	ident "${tmp}/identity-default" "${tmp}/id-default" || :
	ident "${root}/tests/fixtures/identity" "${tmp}/id-cyber" || :
	ident /nonexistent "${tmp}/id-none" || :
	corner=$(python3 -I -B -c '
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
sys.path.insert(0, sys.argv[1])
import branding
def region(path):
    p = GdkPixbuf.Pixbuf.new_from_file(path)
    # The lower left: the bottom 40 pixels of the sidebar.
    sub = p.new_subpixbuf(8, p.get_height() - 40, 220, 40)
    data, stride, n = sub.get_pixels(), sub.get_rowstride(), sub.get_n_channels()
    px = [data[y * stride + x * n:y * stride + x * n + 3] for y in range(40) for x in range(220)]
    return px
def hexc(t):
    return "%02X%02X%02X" % tuple(t)
out = []
for path in sys.argv[2:4]:
    px = region(path)
    lum = sorted(px, key=lambda c: branding.luminance(hexc(c)))
    # The background is the most common colour, the text its farthest.
    bg = max(set(map(bytes, px)), key=px.count)
    far = max(px, key=lambda c: branding.contrast(hexc(c), hexc(bg)))
    out.append("%.1f" % branding.contrast(hexc(far), hexc(bg)))
none = region(sys.argv[4])
out.append("same" if none == region(sys.argv[2]) else "differ")
print(" ".join(out))' "${root}/lib" "${tmp}/id-default/identity.png" "${tmp}/id-cyber/identity.png" \
		"${tmp}/id-none/identity.png" 2>&1) || corner="error ${corner}"
	set -- ${corner}
	ok=$(python3 -I -B -c 'import sys; print("yes" if float(sys.argv[1]) >= 4.5 and float(sys.argv[2]) >= 4.5 else "no")' \
		"${1:-0}" "${2:-0}" 2>/dev/null || echo no)
	check "the identity line is readable on both palettes (${1:-?}:1, ${2:-?}:1)" yes "${ok}"
	check "the identity line follows the identity file" differ "${3:-}"
	# The flags of the language picker are images shipped with the
	# installer, never characters an emoji font has to draw; without the
	# images, the two letters of the region in a badge, never an empty box.
	printf '[{"name": "flags-welcome", "page": "welcome", "full": false, "state": {"locale": "de_DE.UTF-8", "report": "flags"}}]\n' \
		> "${tmp}/flags.json"
	flagrun() { # flagrun <installer root> <shots dir>
		rm -rf "$2" && mkdir "$2"
		GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
			INSTALLER_ARTWORK="${root}/tests/fixtures/artwork" INSTALLER_IDENTITY="${root}/tests/fixtures/identity-default" \
			"$1/bin/installer-gui" --render "${tmp}/flags.json" --size 1024x768 --screenshots "$2" \
			> "${tmp}/render.log" 2>&1
	}
	kinds() {
		python3 -I -B -c '
import json, sys
r = json.load(open(sys.argv[1]))
print(len(r), " ".join(sorted({x["kind"] for x in r})))' "$1" 2>/dev/null || echo none
	}
	locales=$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import i18n
print(sum(len(l[3]) for l in i18n.LANGUAGES))' "${root}/lib")
	flagrun "${root}" "${tmp}/flags" || :
	check "every flag of the picker is an image" "${locales} image" "$(kinds "${tmp}/flags/flags-welcome.flags.json")"
	mkdir -p "${tmp}/noflags"
	cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" "${root}/installer.conf" \
		"${tmp}/noflags/"
	mkdir -p "${tmp}/noflags/gui"
	flagrun "${tmp}/noflags" "${tmp}/flags-none" || :
	check "without the images every flag is a badge with its letters" "${locales} badge" \
		"$(kinds "${tmp}/flags-none/flags-welcome.flags.json")"
	# A picture of it.
	[ -s "${tmp}/flags/flags-welcome.png" ] && got=yes || got=no
	check "the Welcome page with the flags is rendered" yes "${got}"

	# A slow disk probe (PROBE_DELAY=3, as reading the disks of some
	# systems takes minutes) runs beside the main loop: the window keeps
	# turning, and the disks are read once for the visit.
	sed 's/^DISKS_DETAIL=.*/&/' "${root}/tests/fixtures/disks/dual-os.conf" > "${tmp}/slow.conf"
	sed -i.bak "s|^DISKS_DETAIL=|DISKS_DETAIL=${root}/tests/fixtures/disks/|; s|^LICENSED_CATALOGUE=\.\./|LICENSED_CATALOGUE=${root}/tests/fixtures/|; s|^HARDWARE=\.\./|HARDWARE=${root}/tests/fixtures/|" "${tmp}/slow.conf"
	printf 'PROBE_DELAY=3\n' >> "${tmp}/slow.conf"
	printf '[{"name": "slow-disk", "page": "disk", "full": false, "state": {"report": "busy"}}]\n' > "${tmp}/slow.json"
	rm -rf "${tmp}/slow" && mkdir "${tmp}/slow"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" \
		INSTALLER_ADAPTER_FIXTURE="${tmp}/slow.conf" \
		bin/installer-gui --render "${tmp}/slow.json" --size 1024x768 --screenshots "${tmp}/slow" \
		> "${tmp}/render.log" 2>&1 || :
	busy=$(python3 -I -B -c '
import json, sys
b = json.load(open(sys.argv[1]))
print("yes" if b["longest"] >= 3 and b["iterations"] >= 100 else "no %r" % b)' "${tmp}/slow/slow-disk.busy.json" 2>&1)
	check "the main loop runs while a slow probe sleeps" yes "${busy}"

	# OpenBSD: a layout that is an encryption (CRYPTO) ticks and locks the
	# encryption box; a plain layout leaves it to the person.
	sed 's/^OS=.*/OS=openbsd/' installer.conf > "${tmp}/openbsd.conf"
	printf '%s\n' '[{"name": "crypto", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "usage": "together", "layout": "crypto", "report": "encryption"}},' \
		'{"name": "single", "page": "disk", "full": false, "state": {"mode": "erase", "selected": ["nda0"], "usage": "together", "layout": "single", "report": "encryption"}}]' \
		> "${tmp}/enc.json"
	rm -rf "${tmp}/enc" && mkdir "${tmp}/enc"
	GDK_BACKEND=broadway BROADWAY_DISPLAY=":${n}" INSTALLER_STATE_PARENT="${tmp}" INSTALLER_CONF="${tmp}/openbsd.conf" \
		INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/disks/dual-os.conf" \
		bin/installer-gui --render "${tmp}/enc.json" --size 1024x768 --screenshots "${tmp}/enc" \
		> "${tmp}/render.log" 2>&1 || :
	enc() { python3 -I -B -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r["layout"], r["active"], r["sensitive"])' "$1" 2>&1; }
	check "CRYPTO ticks and locks the encryption box" "crypto True False" "$(enc "${tmp}/enc/crypto.encryption.json")"
	check "a plain layout leaves the box to the person" "single True True" "$(enc "${tmp}/enc/single.encryption.json")"

	# A palette that cannot be used: the built-in look, a warning, no crash.
	mkdir -p "${tmp}/art"
	cp -R "${root}/tests/fixtures/artwork/." "${tmp}/art/"
	printf 'PRIMARY=$(id)\n' >> "${tmp}/art/palette.env"
	render "${tmp}/art" "${tmp}/shots" && rc=0 || rc=$?
	check_rc "a bad palette does not stop the installer" 0 "${rc}"
	check_contains "it says why" "the artwork cannot be used" "$(cat "${tmp}/render.log")"
	kill "${bpid}" 2>/dev/null || :
else
	printf 'skip the drawing checks: no broadwayd or PyGObject\n'
fi

finish

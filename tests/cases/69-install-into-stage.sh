#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# install-into-stage.sh puts the installer, the launcher, the menu and
# desktop entries and the start of the live session into the tree of a live
# image, and writes nothing outside that tree.  The launcher picks the
# graphical front end under X and the text one without, and takes a user
# that is not root there through doas or sudo.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-stage.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# iis — install-into-stage.sh as a build without root: with a METALOG.
iis() {
	"${root}/install-into-stage.sh" "$@" --metalog "${tmp}/METALOG"
}

stage="${tmp}/stage"
outside="${tmp}/outside"
mkdir -p "${stage}" "${outside}"
printf 'PRODUCT_NAME=Acme Desktop\nPRODUCT_SLUG=acme\nOS=netbsd\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\nPRODUCT_LOGO=/usr/local/share/acme/logo.png\n' \
	> "${tmp}/acme.conf"

rc=0
iis "${stage}" --conf "${tmp}/acme.conf" >/dev/null 2>&1 || rc=$?
check_rc "the installer is installed into the stage" 0 "${rc}"

lx="${stage}/usr/local/libexec/wtfbsd-installer"
for f in bin/installer-backend bin/installer-config bin/installer-tui bin/installer-gui \
	bin/installer-session lib/gating.py lib/passhash.py lib/wizard.py lib/adapter.sh \
	lib/backend.sh lib/config.sh lib/accounts.sh sections.d/users.sh adapters/netbsd.sh \
	installer.conf; do
	check "the stage holds ${f}" yes "$([ -f "${lx}/${f}" ] && echo yes || echo no)"
done
check "the launcher is executable" yes \
	"$([ -x "${stage}/usr/local/bin/wtfbsd-installer" ] && echo yes || echo no)"
check "the configuration of the template is the one installed" \
	"$(cat "${tmp}/acme.conf")" "$(cat "${lx}/installer.conf")"
check "no test is installed" "" "$(cd "${stage}" && find . -path '*tests*' -print)"

entry="${stage}/usr/local/share/applications/wtfbsd-installer.desktop"
check_contains "the menu entry names the product" "Name=Install Acme Desktop" "$(cat "${entry}")"
check_contains "the menu entry starts the launcher" \
	"Exec=/usr/local/bin/wtfbsd-installer --graphical" "$(cat "${entry}")"
check_contains "the logo of the configuration is the icon" \
	"Icon=/usr/local/share/acme/logo.png" "$(cat "${entry}")"
check "the desktop copy of the entry is executable" yes \
	"$([ -x "${stage}/usr/local/share/wtfbsd-installer/desktop/wtfbsd-installer.desktop" ] && echo yes || echo no)"
auto="${stage}/usr/local/share/wtfbsd-installer/autostart/wtfbsd-installer.desktop"
check_contains "the autostart entry starts the session helper" \
	"Exec=/usr/local/libexec/wtfbsd-installer/bin/installer-session" "$(cat "${auto}")"
check "no placeholder is left" "" \
	"$(grep -rl '@[A-Z]*@' "${stage}/usr/local/bin" "${stage}/usr/local/share" "${lx}/bin/installer-session" || true)"
check "nothing autostarts on the installed system by itself" "" \
	"$(find "${stage}" -path '*/xdg/autostart*' -print)"
manifest=$(cat "${stage}/usr/local/share/wtfbsd-installer/MANIFEST")
check_contains "the manifest lists the launcher" "/usr/local/bin/wtfbsd-installer" "${manifest}"
check_contains "the manifest lists the menu entry" \
	"/usr/local/share/applications/wtfbsd-installer.desktop" "${manifest}"
check "the manifest lists every file that was installed" \
	"$(cd "${stage}" && find . -type f | sed 's/^\.//' | sort)" \
	"$(printf '%s\n' "${manifest}" | grep -v '/$' | sort)"
check "the manifest lists the directories of the installer, and only those" \
	"$( (cd "${stage}" && find ./usr/local/libexec/wtfbsd-installer ./usr/local/share/wtfbsd-installer -type d) | sed -e 's/^\.//' -e 's|$|/|' | sort)" \
	"$(printf '%s\n' "${manifest}" | grep '/$' | sort)"
check_absent "the manifest never lists a shared directory" "/usr/local/bin/
" "${manifest}
"
# The deepest directory comes before its parent and the directories come
# after the files: removing the lines in order empties every directory
# before it is removed.
order=$(printf '%s\n' "${manifest}" | awk '
	/\/$/ { seen_dir = 1; depth = gsub("/", "/"); if (last && depth > last) bad = 1; last = depth; next }
	seen_dir { bad = 1 }
	END { print bad ? "wrong" : "ok" }')
check "the files come first, then the directories, the deepest first" ok "${order}"
removal="${tmp}/removal"
mkdir -p "${removal}"
(cd "${stage}" && tar -cf - .) | (cd "${removal}" && tar -xf -)
printf '%s\n' "${manifest}" | while IFS= read -r path; do
	case "${path}" in
		*/) rmdir "${removal}${path}" ;;
		*) rm -f "${removal}${path}" ;;
	esac
done 2>"${tmp}/removal.err" || :
check "removing the manifest in order leaves nothing of the installer" "" \
	"$( (cd "${removal}" && find . -path '*wtfbsd-installer*' -print) ; cat "${tmp}/removal.err")"

# The root helper is in the libexec directory, mode 0555 (root:wheel when
# the stage is built as root).
helper="${lx}/installer-apply"
check "the root helper is installed" yes "$([ -f "${helper}" ] && echo yes || echo no)"
check "the root helper is mode 0555" 555 \
	"$(stat -c %a "${helper}" 2>/dev/null || stat -f %Lp "${helper}")"
out=$("${helper}" --bogus 2>&1 || :)
check_contains "the installed helper runs and refuses an unknown verb" "ERROR usage" "${out}"

# ------------------------------------------------- ownership: the METALOG
# The build without root gives every installed path to root through the
# METALOG: one line for every file and every directory of the installer,
# with the mode it has in the stage.
metalog=$(cat "${tmp}/METALOG")
missing=''
for path in $(printf '%s\n' "${manifest}"); do
	case "${path}" in
		*/) want=".${path%/} type=dir uname=root gname=wheel mode=" ;;
		*) want=".${path} type=file uname=root gname=wheel mode=" ;;
	esac
	printf '%s\n' "${metalog}" | grep -qF -- "${want}" || missing="${missing} ${path}"
done
check "the METALOG gives every path of the manifest to root:wheel" "" "${missing}"
check_contains "the METALOG keeps the mode of the root helper" \
	"./usr/local/libexec/wtfbsd-installer/installer-apply type=file uname=root gname=wheel mode=0555" "${metalog}"
check_contains "the METALOG keeps the mode of a library" \
	"./usr/local/libexec/wtfbsd-installer/lib/apply.py type=file uname=root gname=wheel mode=0644" "${metalog}"
check_contains "the METALOG names the directories the script made" \
	"./usr/local/bin type=dir uname=root gname=wheel mode=0755" "${metalog}"
check "every line of the METALOG is a line of mtree for root" "" \
	"$(printf '%s\n' "${metalog}" | grep -vE '^\./[^ ]+ type=(file|dir) uname=root gname=wheel mode=0[0-7]{3}$' || true)"
check "nothing in the stage may be written by the group or the others" "" \
	"$(find "${stage}" -mindepth 1 \( -perm -020 -o -perm -002 \) | grep -v '^$' || true)"

# Without root and without --metalog nothing is installed.
bare="${tmp}/bare"
mkdir -p "${bare}"
rc=0
out=$("${root}/install-into-stage.sh" "${bare}" 2>&1) || rc=$?
check_rc "without root and without --metalog the script refuses" 2 "${rc}"
check_contains "it says why" "no --metalog" "${out}"
check "and it installs nothing" "" "$(find "${bare}" -mindepth 1 -print)"
ln -s "${tmp}/elsewhere" "${tmp}/METALOG.link"
rc=0
"${root}/install-into-stage.sh" "${bare}" --metalog "${tmp}/METALOG.link" >/dev/null 2>&1 || rc=$?
check_rc "a METALOG that is a link is refused" 2 "${rc}"

# ------------------------------------------------- ownership: as root
# As root the whole installed tree is given to root:wheel and the write bit
# of the group and the others is taken away: chown and chmod stand-ins
# write down what they are asked, and id says 0.
asroot="${tmp}/asroot"
mkdir -p "${asroot}/bin" "${tmp}/rootstage"
printf '#!/bin/sh\necho 0\n' > "${asroot}/bin/id"
printf '#!/bin/sh\necho "chown $*" >> "%s/ownership"\n' "${tmp}" > "${asroot}/bin/chown"
printf '#!/bin/sh\ncase "$1" in -R) echo "chmod $*" >> "%s/ownership" ;; esac\nexec /bin/chmod "$@"\n' \
	"${tmp}" > "${asroot}/bin/chmod"
chmod +x "${asroot}/bin/"*
rc=0
PATH="${asroot}/bin:${PATH}" "${root}/install-into-stage.sh" "${tmp}/rootstage" >/dev/null 2>&1 || rc=$?
check_rc "as root no METALOG is needed" 0 "${rc}"
ownership=$(cat "${tmp}/ownership" 2>/dev/null || true)
rs="${tmp}/rootstage/usr/local"
for top in libexec/wtfbsd-installer share/wtfbsd-installer bin/wtfbsd-installer \
	share/applications/wtfbsd-installer.desktop; do
	check_contains "as root ${top} is given to root:wheel" "chown -R 0:0 ${rs}/${top}" "${ownership}"
	check_contains "as root ${top} is not writable by others" "chmod -R go-w ${rs}/${top}" "${ownership}"
done

# The installed backend runs from the stage.
out=$(INSTALLER_ADAPTER_FIXTURE="${root}/tests/fixtures/adapter-fixture.conf" \
	"${lx}/bin/installer-backend" welcome probe 2>&1 || :)
check_contains "the installed backend runs" '"product":"Acme Desktop"' "${out}"

# A prefix of its own.
rc=0
iis "${stage}" --prefix /opt/inst >/dev/null 2>&1 || rc=$?
check_rc "a prefix of its own" 0 "${rc}"
check "the launcher is under the prefix" yes \
	"$([ -x "${stage}/opt/inst/bin/wtfbsd-installer" ] && echo yes || echo no)"

# Refusals.
for bad in / "${tmp}/nonexistent" ""; do
	rc=0
	iis "${bad}" >/dev/null 2>&1 || rc=$?
	check_rc "DESTDIR '${bad}' is refused" 2 "${rc}"
done
# A path that resolves to the root of the system.
ln -s / "${tmp}/rootlink"
rc=0
iis "${tmp}/rootlink" >/dev/null 2>&1 || rc=$?
check_rc "a DESTDIR that is a link to / is refused" 2 "${rc}"
for bad in usr/local ../x /usr/../etc; do
	rc=0
	iis "${stage}" --prefix "${bad}" >/dev/null 2>&1 || rc=$?
	check_rc "the prefix '${bad}' is refused" 2 "${rc}"
done
# A link in the stage that points out of it is never followed.
stage2="${tmp}/stage2"
mkdir -p "${stage2}/usr"
ln -s "${outside}" "${stage2}/usr/local"
rc=0
iis "${stage2}" >/dev/null 2>&1 || rc=$?
check_rc "a link on the way out of the stage is refused" 2 "${rc}"
check "nothing was written through the link" "" "$(find "${outside}" -mindepth 1 -print)"
stage3="${tmp}/stage3"
mkdir -p "${stage3}/usr/local/bin"
ln -s "${outside}/victim" "${stage3}/usr/local/bin/wtfbsd-installer"
rc=0
iis "${stage3}" >/dev/null 2>&1 || rc=$?
check_rc "a file that is a link is refused" 2 "${rc}"
check "nothing was written through the file link" "" "$(find "${outside}" -mindepth 1 -print)"
rc=0
printf 'PRODUCT_NAME=$(touch x)\n' > "${tmp}/bad.conf"
iis "${stage}" --conf "${tmp}/bad.conf" >/dev/null 2>&1 || rc=$?
check_rc "a configuration that is not valid is refused" 2 "${rc}"

# ---------------------------------------------------- names of the stage
# The MANIFEST and the METALOG hold one path per line, and mtree splits a
# line at a blank: a name with a blank or a newline would make a line that
# says something else.  Every name is checked before anything is installed.
NL='
'
names="${tmp}/names"
for bad in 'with space' "with${NL}newline"; do
	rm -rf "${names}"
	mkdir -p "${names}/src" "${names}/stage"
	cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" "${root}/gui" \
		"${root}/stage" "${root}/LICENSE" "${root}/installer.conf" "${root}/install-into-stage.sh" \
		"${names}/src/"
	printf '# x\n' > "${names}/src/lib/${bad}.sh"
	: > "${names}/METALOG"
	rc=0
	out=$("${names}/src/install-into-stage.sh" "${names}/stage" --metalog "${names}/METALOG" 2>&1) || rc=$?
	label=$(printf '%s' "${bad}" | tr '\n' '/')
	check_rc "a file named '${label}' is refused" 2 "${rc}"
	check_contains "the refusal of '${label}' says why" "not a plain name" "${out}"
	check "for '${label}' nothing is installed" "" "$(find "${names}/stage" -mindepth 1 -print)"
	check "for '${label}' the METALOG is not written" "" "$(cat "${names}/METALOG")"
	# A directory of that name already in the directories of the installer.
	rm -f "${names}/src/lib/${bad}.sh"
	mkdir -p "${names}/stage/usr/local/libexec/wtfbsd-installer/${bad}"
	rc=0
	out=$("${names}/src/install-into-stage.sh" "${names}/stage" --metalog "${names}/METALOG" 2>&1) || rc=$?
	check_rc "a directory named '${label}' in the stage is refused" 2 "${rc}"
	check "for the directory '${label}' nothing is installed" "" \
		"$(find "${names}/stage" -type f -print)"
	check "for the directory '${label}' the METALOG is not written" "" "$(cat "${names}/METALOG")"
done

# ---------------------------------------------------------- the launcher
# The front ends of the stage are replaced by stand-ins that say which one
# ran, with its arguments and the variables of its environment that matter.
fake="${tmp}/fakebin"
mkdir -p "${fake}"
printf '#!/bin/sh\necho 1000\n' > "${fake}/id"
printf '#!/bin/sh\necho "DOAS $*" >> "%s/escalations"\n' "${tmp}" > "${fake}/doas"
printf '#!/bin/sh\necho "SUDO $*" >> "%s/escalations"\n' "${tmp}" > "${fake}/sudo"
chmod +x "${fake}/id" "${fake}/doas" "${fake}/sudo"
cat > "${lx}/bin/installer-gui" <<'STUB'
#!/bin/sh
echo "GUI $*"
exit 10
STUB
cat > "${lx}/bin/installer-tui" <<'STUB'
#!/bin/sh
echo "TUI $*"
env | grep -E '^(INSTALLER_|BSDDIALOG|LD_PRELOAD|PYTHONPATH|GTK_MODULES|XDG_CONFIG_HOME|DISPLAY)' | sort
STUB
# The launcher of the stage names the paths of the target system; the test
# runs a copy that names the stage.
sed -e "s|^libexec=.*|libexec='${lx}'|" \
	"${stage}/usr/local/bin/wtfbsd-installer" > "${tmp}/launcher"
chmod +x "${tmp}/launcher"
rc=0
out=$(PATH="${fake}:${PATH}" DISPLAY=:9 "${tmp}/launcher" 2>&1) || rc=$?
check "under X the launcher starts the graphical front end as the user" "GUI " "${out}"
check_rc "the exit code of the front end is passed on (Try the live desktop)" 10 "${rc}"
out=$(env -u DISPLAY PATH="${fake}:${PATH}" "${tmp}/launcher" 2>&1 || :)
check "without X the launcher starts the text front end" "TUI " "${out}"
out=$(env -u DISPLAY PATH="${fake}:${PATH}" DISPLAY=:9 "${tmp}/launcher" --text 2>&1 || :)
check_contains "--text starts the text front end under X" "TUI " "${out}"
# No argument but the mode reaches a front end.
for args in '--graphical --windowed' '--smoke x' '--graphical --display :5' '--bogus'; do
	rc=0
	# shellcheck disable=SC2086
	out=$(PATH="${fake}:${PATH}" DISPLAY=:9 "${tmp}/launcher" ${args} 2>&1) || rc=$?
	check_rc "the launcher refuses '${args}'" 2 "${rc}"
	check_absent "no front end ran for '${args}'" "GUI" "${out}"
done
check "the launcher never runs doas or sudo itself" "" \
	"$(cat "${tmp}/escalations" 2>/dev/null || true)"

# Root gets the text front end, never the graphical one, and none of the
# variables of the caller.
printf '#!/bin/sh\necho 0\n' > "${fake}/id"
out=$(PATH="${fake}:${PATH}" DISPLAY=:9 INSTALLER_ROOT=/nonexistent BSDDIALOG=/bin/false \
	LD_PRELOAD=/nonexistent.so PYTHONPATH=/nonexistent GTK_MODULES=evil \
	XDG_CONFIG_HOME=/nonexistent INSTALLER_ADAPTER_FIXTURE=/nonexistent \
	"${tmp}/launcher" --graphical 2>&1 || :)
# The processes before the scrub (the launcher itself and id) are the
# caller's own and print the warnings of the loader about LD_PRELOAD; doas
# and sudo drop it before a real root ever gets there.  What the front end
# sees is what counts: no variable of the caller.
check "root gets the text front end with a clean environment" "TUI " \
	"$(printf '%s\n' "${out}" | grep -v '^ERROR: ld.so')"

# ---------------------------------------------------- the session helper
# The helper puts the icon on the desktop and opens the installer, unless
# "Try the live desktop" was chosen since this boot.
home="${tmp}/home"
mkdir -p "${home}"
printf '#!/bin/sh\necho launched >> "%s/launches"\nexit "${LAUNCH_RC:-10}"\n' "${tmp}" \
	> "${tmp}/fake-launcher"
chmod +x "${tmp}/fake-launcher"
sed -e "s|^launcher=.*|launcher='${tmp}/fake-launcher'|" \
	-e "s|^entry=.*|entry='${entry}'|" "${lx}/bin/installer-session" > "${tmp}/session"
chmod +x "${tmp}/session"
session() {
	env -u XDG_RUNTIME_DIR HOME="${home}" PATH="${root}/tests/stubs:${PATH}" "$@" \
		sh "${tmp}/session" >/dev/null 2>&1 || :
}
session
check "the icon is on the desktop" yes \
	"$([ -x "${home}/Desktop/wtfbsd-installer.desktop" ] && echo yes || echo no)"
check "the installer opened" 1 "$(wc -l < "${tmp}/launches" | tr -d ' ')"
session
check "after Try the live desktop it does not open again in this boot" 1 \
	"$(wc -l < "${tmp}/launches" | tr -d ' ')"
session STUB_BOOTTIME='{ sec = 1800000000, usec = 0 }'
check "after the next boot it opens again" 2 "$(wc -l < "${tmp}/launches" | tr -d ' ')"


# --artwork: the look of the product goes next to the installer, and only
# artwork the installer can use.
art_stage="${tmp}/art-stage"
mkdir -p "${art_stage}"
rm -f "${tmp}/METALOG"
iis "${art_stage}" --conf "${tmp}/acme.conf" --artwork "${root}/tests/fixtures/artwork" && rc=0 || rc=$?
check_rc "the artwork is staged" 0 "${rc}"
for f in palette.env src/logo.svg src/wallpaper-2.svg variants/cyberpunk/palette.env; do
	[ -f "${art_stage}/usr/local/libexec/wtfbsd-installer/artwork/${f}" ] && got=yes || got=no
	check "the artwork has ${f}" yes "${got}"
done
check_contains "the MANIFEST lists the artwork" "/usr/local/libexec/wtfbsd-installer/artwork/" \
	"$(cat "${art_stage}/usr/local/share/wtfbsd-installer/MANIFEST")"
mkdir -p "${tmp}/bad-art"
printf 'PRIMARY=red\n' > "${tmp}/bad-art/palette.env"
bad_stage="${tmp}/bad-stage"
mkdir -p "${bad_stage}"
iis "${bad_stage}" --conf "${tmp}/acme.conf" --artwork "${tmp}/bad-art" 2>/dev/null && rc=0 || rc=$?
check_rc "artwork the installer cannot use is refused" 2 "${rc}"
check "nothing was staged" "" "$(find "${bad_stage}" -type f | head -1)"


# The flags of the language picker and their notice are staged and listed.
manifest=$(cat "${art_stage}/usr/local/share/wtfbsd-installer/MANIFEST")
check_contains "the MANIFEST lists a flag" "/usr/local/libexec/wtfbsd-installer/gui/flags/de.png" "${manifest}"
check_contains "the MANIFEST lists a 2x flag" "/usr/local/libexec/wtfbsd-installer/gui/flags/de-2x.png" "${manifest}"
check_contains "the MANIFEST lists the third-party notice" "/usr/local/libexec/wtfbsd-installer/THIRD-PARTY" "${manifest}"

finish

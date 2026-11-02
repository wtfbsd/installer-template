#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# install-into-stage.sh DESTDIR [--prefix /usr/local] [--conf FILE] [--metalog FILE]
#                       [--artwork DIR]
#
# Installs the installer into the tree of a live image that is being built
# (the stage), and nothing else:
#
#   PREFIX/libexec/wtfbsd-installer/      bin, lib, sections.d, adapters,
#                                         gui and installer.conf (--conf)
#   PREFIX/libexec/wtfbsd-installer/artwork/
#                                         --artwork DIR: palette.env, the
#                                         SVG sources (src/) and the slides
#                                         (slides/slides.txt) of the artwork
#                                         template of the product: the look
#                                         of the installer
#   PREFIX/libexec/wtfbsd-installer/installer-apply
#                                         the root helper, root 0555 (group
#                                         of root, gid 0):
#                                         the only file the doas or sudo rule
#                                         of the live system may name
#   PREFIX/bin/wtfbsd-installer           the launcher: the graphical front
#                                         end under X, the text one without
#   PREFIX/share/applications/wtfbsd-installer.desktop
#                                         "Install <product>" for the menu
#   PREFIX/share/wtfbsd-installer/desktop/wtfbsd-installer.desktop
#                                         the same entry, for the desktop
#   PREFIX/share/wtfbsd-installer/autostart/wtfbsd-installer.desktop
#                                         the start of the live session; the
#                                         template copies it into the
#                                         autostart directory of the live user
#   PREFIX/share/wtfbsd-installer/MANIFEST
#                                         every file above, one per line, and
#                                         then the directories of the
#                                         installer with a trailing slash,
#                                         the deepest first, so the install
#                                         command can remove the files and
#                                         then rmdir the directories
#
# Everything it installs belongs to root and nobody else may write it: the
# root helper runs it as root.  Run as root, the script gives the whole
# installed tree to root and the group of root (gid 0: wheel on the BSDs,
# root on illumos, from lib/osinfo.sh and the OS of the configuration) and
# takes the write bit of the group and of the others away.  An image that is built without root (NO_ROOT, makefs
# with a METALOG) gives it to root through the METALOG instead: the script
# then requires --metalog FILE and appends an mtree line
#   ./path type=file|dir uname=root gname=<group of root> mode=0755
# for every path it installs and every directory it makes.  Without root
# and without --metalog it refuses and installs nothing.
#
# Every path is under DESTDIR (the METALOG is the file the caller names).  DESTDIR has to be a directory and may not be
# the root of the running system, and no directory on the way may be a
# symbolic link: a link in the stage could point out of it.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)

die() {
	printf 'install-into-stage: %s\n' "$*" >&2
	exit 2
}

usage() {
	printf 'usage: install-into-stage.sh DESTDIR [--prefix /usr/local] [--conf FILE] [--metalog FILE] [--artwork DIR]\n' >&2
	exit 2
}

[ $# -ge 1 ] || usage
destdir_arg=$1
shift
prefix=/usr/local
conf=${here}/installer.conf
metalog=
artwork=
while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) [ $# -ge 2 ] || usage; prefix=$2; shift 2 ;;
		--conf) [ $# -ge 2 ] || usage; conf=$2; shift 2 ;;
		--metalog) [ $# -ge 2 ] || usage; metalog=$2; shift 2 ;;
		--artwork) [ $# -ge 2 ] || usage; artwork=$2; shift 2 ;;
		*) usage ;;
	esac
done

[ -n "${destdir_arg}" ] || die 'DESTDIR is empty'
[ -d "${destdir_arg}" ] || die "DESTDIR is not a directory: ${destdir_arg}"
destdir=$(CDPATH= cd -P "${destdir_arg}" && pwd -P)
[ "${destdir}" != / ] || die 'DESTDIR is the root of the running system; refusing'

printf '%s\n' "${prefix}" | grep -Eq '^/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$' ||
	die "the prefix must be an absolute path of plain names: ${prefix}"
case "/${prefix}/" in
	*/../*|*/./*) die "the prefix may not hold . or ..: ${prefix}" ;;
esac

as_root=no
[ "$(id -u)" = 0 ] && as_root=yes
if [ "${as_root}" = no ] && [ -z "${metalog}" ]; then
	die 'not root and no --metalog: the installed files would not belong to root; run as root, or give --metalog FILE for an image built without root'
fi
if [ -n "${metalog}" ]; then
	[ ! -L "${metalog}" ] || die "the METALOG is a symbolic link: ${metalog}"
	[ ! -e "${metalog}" ] || [ -f "${metalog}" ] || die "the METALOG is not a file: ${metalog}"
	: >> "${metalog}" || die "cannot write the METALOG: ${metalog}"
fi

[ -f "${conf}" ] || die "no configuration file: ${conf}"
if [ -n "${artwork}" ]; then
	[ -f "${artwork}/palette.env" ] || die "the artwork has no palette.env: ${artwork}"
	python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import branding; branding.load(sys.argv[2])' \
		"${here}/lib" "${artwork}" || die "the artwork cannot be used: ${artwork}"
fi
INSTALLER_CONF=${conf} "${here}/bin/installer-config" validate ||
	die "the configuration is not valid: ${conf}"
conf_get() {
	INSTALLER_CONF=${conf} "${here}/bin/installer-config" get "$1"
}
product=$(conf_get PRODUCT_NAME)
# The owner of everything installed: root and the group of root of the
# system the image is for (no wheel on illumos).
. "${here}/lib/osinfo.sh"
os=$(conf_get OS)
unknown_os="unknown OS '${os}' (add it to lib/osinfo.sh)"
root_group=$(os_root_group "${os}") || die "${unknown_os}"
root_gid=$(os_root_gid "${os}") || die "${unknown_os}"
logo=$(conf_get PRODUCT_LOGO 2>/dev/null) || logo=''
icon=${logo:-system-software-install}

libexec=${prefix}/libexec/wtfbsd-installer
bindir=${prefix}/bin
appdir=${prefix}/share/applications
share=${prefix}/share/wtfbsd-installer

manifest_tmp=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-stage-manifest.XXXXXX")
made_dirs=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-stage-dirs.XXXXXX")
trap 'rm -f "${manifest_tmp}" "${made_dirs}"' EXIT INT TERM HUP

# stage_dir <path> — make a directory of the stage, every component under
# DESTDIR checked: none of them may be a symbolic link.
stage_dir() {
	_path=$1
	_cur=${destdir}
	_rest=${_path#/}
	while [ -n "${_rest}" ]; do
		_comp=${_rest%%/*}
		if [ "${_comp}" = "${_rest}" ]; then
			_rest=''
		else
			_rest=${_rest#*/}
		fi
		_cur=${_cur}/${_comp}
		[ ! -L "${_cur}" ] || die "a symbolic link is in the way: ${_cur}"
		if [ ! -d "${_cur}" ]; then
			[ ! -e "${_cur}" ] || die "not a directory: ${_cur}"
			mkdir "${_cur}"
			chmod 755 "${_cur}"
			printf '%s\n' "${_cur#"${destdir}"}" >> "${made_dirs}"
		fi
	done
}

# check_name <path> — every component of a path of the stage is a plain
# name of [A-Za-z0-9._+@-], not . or ..: the MANIFEST and the METALOG
# hold one path per line and mtree splits a line at a blank, so a blank, a
# newline or any other character would make a line that says something
# else.
check_name() {
	_rest=${1#/}
	[ -n "${_rest}" ] || die "an empty path"
	while :; do
		_comp=${_rest%%/*}
		case "${_comp}" in
			''|.|..|*[!A-Za-z0-9._+@-]*)
				die "a name of the stage that is not a plain name: $(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._+@/-' '?') (each ? is a character that is not allowed)"
				;;
		esac
		[ "${_comp}" != "${_rest}" ] || break
		_rest=${_rest#*/}
	done
}

# pass — check: every path is checked and nothing is written; stage: the
# files are installed.  The first pass runs to its end before the second.
pass=check

# stage_file <source> <target path> <mode> — copy one file into the stage
# through a file of its own that is moved into place.
stage_file() {
	if [ "${pass}" = check ]; then
		check_name "$2"
		[ -f "$1" ] || die "no such file: $1"
		return 0
	fi
	_dst=${destdir}$2
	stage_dir "${2%/*}"
	[ ! -L "${_dst}" ] || die "a symbolic link is in the way: ${_dst}"
	[ ! -d "${_dst}" ] || die "a directory is in the way: ${_dst}"
	_tmp=$(mktemp "${_dst}.XXXXXX")
	if ! cp "$1" "${_tmp}"; then
		rm -f "${_tmp}"
		die "cannot copy $1"
	fi
	chmod "$3" "${_tmp}"
	mv -f "${_tmp}" "${_dst}"
	printf '%s\n' "$2" >> "${manifest_tmp}"
}

# stage_template <source> <target path> <mode> — a file of stage/ with its
# placeholders filled in.
stage_template() {
	if [ "${pass}" = check ]; then
		check_name "$2"
		[ -f "$1" ] || die "no such file: $1"
		return 0
	fi
	_filled=$(mktemp "${TMPDIR:-/tmp}/wtfbsd-stage.XXXXXX")
	sed -e "s|@PRODUCT@|${product}|g" -e "s|@LIBEXEC@|${libexec}|g" \
		-e "s|@BINDIR@|${bindir}|g" -e "s|@APPDIR@|${appdir}|g" \
		-e "s|@ICON@|${icon}|g" "$1" > "${_filled}"
	stage_file "${_filled}" "$2" "$3"
	rm -f "${_filled}"
}

stage_all() {
for f in installer-backend installer-config installer-tui installer-gui; do
	stage_file "${here}/bin/${f}" "${libexec}/bin/${f}" 755
done
# The root helper: root, the group of root, 0555, so that nobody but root changes it.  A
# stage that is not built as root cannot give it to root; the build of the
# image has to (the template runs this script as root).
stage_file "${here}/bin/installer-apply" "${libexec}/installer-apply" 555

stage_template "${here}/stage/installer-session.in" "${libexec}/bin/installer-session" 755
for f in "${here}"/lib/*.sh "${here}"/lib/*.py; do
	stage_file "${f}" "${libexec}/lib/${f##*/}" 644
done
for f in "${here}"/sections.d/*.sh; do
	stage_file "${f}" "${libexec}/sections.d/${f##*/}" 755
done
for f in "${here}"/adapters/*.sh; do
	stage_file "${f}" "${libexec}/adapters/${f##*/}" 755
done
for f in "${here}"/gui/*; do
	[ -f "${f}" ] || continue
	stage_file "${f}" "${libexec}/gui/${f##*/}" 644
done
# The flags of the language picker (PNG, from flag-icons: THIRD-PARTY).
for f in "${here}"/gui/flags/*.png; do
	[ -f "${f}" ] || continue
	stage_file "${f}" "${libexec}/gui/flags/${f##*/}" 644
done
stage_file "${conf}" "${libexec}/installer.conf" 644
if [ -n "${artwork}" ]; then
	stage_file "${artwork}/palette.env" "${libexec}/artwork/palette.env" 644
	for f in logo wordmark-light installer-sidebar wallpaper-1 wallpaper-2 wallpaper-3; do
		[ -f "${artwork}/src/${f}.svg" ] || continue
		stage_file "${artwork}/src/${f}.svg" "${libexec}/artwork/src/${f}.svg" 644
	done
	if [ -f "${artwork}/slides/slides.txt" ]; then
		stage_file "${artwork}/slides/slides.txt" "${libexec}/artwork/slides/slides.txt" 644
	fi
	# The variants of the template (variants/<name>/palette.env and their
	# own art), each checked like the default.
	for vdir in "${artwork}"/variants/*; do
		[ -f "${vdir}/palette.env" ] || continue
		vname=${vdir##*/}
		printf '%s\n' "${vname}" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' || continue
		python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import branding; branding.parse_palette(sys.argv[2])' \
			"${here}/lib" "${vdir}/palette.env" || die "the variant ${vname} cannot be used"
		stage_file "${vdir}/palette.env" "${libexec}/artwork/variants/${vname}/palette.env" 644
		for f in logo wordmark-light installer-sidebar wallpaper-1 wallpaper-2 wallpaper-3; do
			[ -f "${vdir}/src/${f}.svg" ] || continue
			stage_file "${vdir}/src/${f}.svg" "${libexec}/artwork/variants/${vname}/src/${f}.svg" 644
		done
	done
fi
stage_file "${here}/LICENSE" "${libexec}/LICENSE" 644
stage_file "${here}/THIRD-PARTY" "${libexec}/THIRD-PARTY" 644
stage_template "${here}/stage/wtfbsd-installer.in" "${bindir}/wtfbsd-installer" 755
stage_template "${here}/stage/install.desktop.in" "${appdir}/wtfbsd-installer.desktop" 644
stage_template "${here}/stage/install.desktop.in" \
	"${share}/desktop/wtfbsd-installer.desktop" 755
stage_template "${here}/stage/autostart.desktop.in" \
	"${share}/autostart/wtfbsd-installer.desktop" 644
}

# First every name: of every file to install, and of every directory that
# is already in the directories of the installer in the stage (they are
# listed in the MANIFEST and the METALOG too).  Nothing is installed when
# one of them is not a plain name.
stage_all
check_name "${share}/MANIFEST"
for top in "${libexec}" "${share}"; do
	[ -d "${destdir}${top}" ] || continue
	# find matches each name on its own, so a newline in a name is found
	# as the character it is, not as the end of a line.
	bad=$(cd "${destdir}" && LC_ALL=C find ".${top}" -name '*[!A-Za-z0-9._+@-]*' -print | head -n 1) ||
		die "cannot list ${destdir}${top}"
	[ -z "${bad}" ] || die "a name of the stage that is not a plain name: $(printf '%s' "${bad}" | LC_ALL=C tr -c 'A-Za-z0-9._+@/-' '?') (each ? is a character that is not allowed)"
done
pass=stage
stage_all
printf '%s\n' "${share}/MANIFEST" >> "${manifest_tmp}"
# The directories that belong to the installer, the deepest first, with a
# trailing slash.  The shared directories (bin, share/applications) are not
# the installer's and are not listed.
for top in "${libexec}" "${share}"; do
	(cd "${destdir}" && find ".${top}" -type d) | sed 's|^\.||'
done | awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn -k1,1 | cut -f2 |
	sed 's|$|/|' > "${manifest_tmp}.dirs"
cat "${manifest_tmp}.dirs" >> "${manifest_tmp}"
rm -f "${manifest_tmp}.dirs"
stage_file "${manifest_tmp}" "${share}/MANIFEST" 644
# Root owns all of it: the helper runs lib/, bin/, sections.d/ and
# adapters/ as root.
if [ "${as_root}" = yes ]; then
	for top in "${libexec}" "${share}" "${bindir}/wtfbsd-installer" \
		"${appdir}/wtfbsd-installer.desktop"; do
		chown -R "0:${root_gid}" "${destdir}${top}"
		chmod -R go-w "${destdir}${top}"
	done
fi
# mode_of <path> — the permission bits of a path of the stage, in octal.
mode_of() {
	stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
if [ -n "${metalog}" ]; then
	{
		# The directories this script made and the directories of the
		# installer, then every file.
		{
			cat "${made_dirs}"
			for top in "${libexec}" "${share}"; do
				(cd "${destdir}" && find ".${top}" -type d) | sed 's|^\.||'
			done
		} | sort -u | while IFS= read -r path; do
			printf '.%s type=dir uname=root gname=%s mode=%04o\n' "${path}" "${root_group}" \
				"0$(mode_of "${destdir}${path}")"
		done
		grep -v '/$' "${destdir}${share}/MANIFEST" | while IFS= read -r path; do
			printf '.%s type=file uname=root gname=%s mode=%04o\n' "${path}" "${root_group}" \
				"0$(mode_of "${destdir}${path}")"
		done
	} >> "${metalog}"
fi

printf 'install-into-stage: installed the installer of %s into %s%s\n' \
	"${product}" "${destdir}" "${prefix}"

#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installer writes no byte code of its own: a live system copies the
# tree of the installer to the target, and a leftover cache broke an
# install.  Every Python of the installer runs with -I and with -B, so no
# __pycache__ appears under lib/ or bin/ of the tree it runs from.
#
# The check runs the paths the suite runs (the backend with its sections
# and its adapters, the graphical front end and the root helper) against a
# copy of the tree, and looks for what is left behind.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-nobytecode.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# The tree of the installer, copied: the run must leave nothing in it.
tree="${tmp}/tree"
mkdir -p "${tree}"
for part in bin lib adapters sections.d; do
	cp -R "${root}/${part}" "${tree}/${part}"
done
cp "${root}/installer.conf" "${tree}/installer.conf"
# No cache comes with the copy.
find "${tree}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || :
find "${tree}" -name '*.pyc' -delete 2>/dev/null || :

fixtures="${root}/tests/fixtures"
sed "s/^OS=.*/OS=freebsd/" "${root}/installer.conf" > "${tmp}/freebsd.conf"

# The paths the suite runs.
INSTALLER_CONF="${tmp}/freebsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
	"${tree}/bin/installer-backend" disk probe >/dev/null 2>&1 || :
INSTALLER_CONF="${tmp}/freebsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
	"${tree}/bin/installer-backend" network probe >/dev/null 2>&1 || :
INSTALLER_CONF="${tmp}/freebsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture-software.conf" \
	"${tree}/bin/installer-backend" software probe >/dev/null 2>&1 || :
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 \
	"${tree}/bin/installer-gui" --check >/dev/null 2>&1 || :
INSTALLER_CONF="${tmp}/freebsd.conf" \
	INSTALLER_ADAPTER_FIXTURE="${fixtures}/adapter-fixture.conf" \
	"${tree}/bin/installer-apply" --list disks >/dev/null 2>&1 || :

# Nothing of Python in the tree of the installer.
left=$(find "${tree}/lib" "${tree}/bin" \( -name '__pycache__' -o -name '*.pyc' \) \
	| wc -l | tr -d ' ')
check "the installer writes no byte code in its own tree" "0" "${left}"

# The tree the installer runs from is clean, and so is the one of the
# checkout: the suite itself writes no cache either.
left=$(find "${root}/lib" "${root}/bin" \( -name '__pycache__' -o -name '*.pyc' \) \
	| wc -l | tr -d ' ')
check "the tree of the checkout holds no byte code either" "0" "${left}"

finish

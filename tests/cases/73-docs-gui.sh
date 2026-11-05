#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The documentation says what exists now: the graphical front end, the
# adapters of the four systems, the install command they run, the live
# image, and every new variable of the environment.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

readme=$(cat "${root}/README.md")
gui=$(cat "${root}/gui/README.md")
agents=$(cat "${root}/AGENTS.md")

for word in bin/installer-gui lib/wizard.py lib/passhash.py lib/adapter.sh \
	install-into-stage.sh '<slug>-install -p PLANFILE | -d DISK' 'PROGRESS <0-100>' \
	'## The live image' '## The graphical front end' hash-scheme USER_HASHFILE \
	PRODUCT_LOGO MANIFEST 'Try the live desktop' 'bcrypt-2a' 'hw.disknames' \
	'[-c FULLNAME] [-P]' 'IF:ADDR/MASK:GW' '^[a-z][a-z0-9]{0,14}$' setxkbmap \
	'## Privileges' 'permit nopass live as root cmd /usr/local/libexec/wtfbsd-installer/installer-apply' \
	'env_reset' 'installer-apply --install DIR' 'O_EXCL' '/dev/iso9660/' 'the deepest first' \
	'lib/rootguard.sh' 'python3 -I -B' '--metalog FILE' 'uname=root gname=wheel' \
	'chown -R 0:0' 'cd /' 'at most 64 bytes' 'bin/installer-prompt' 'misc/dialog' \
	'OpenBSD has no bsddialog' '1024x768 and up'; do
	check_contains "the README documents ${word}" "${word}" "${readme}"
done
for name in INSTALLER_INSTALL_COMMAND INSTALLER_ZONEINFO INSTALLER_KEYMAP_DIR \
	INSTALLER_DMESG_BOOT INSTALLER_REHEARSAL_STEP_SECONDS INSTALLER_REBOOT_COMMAND; do
	check_contains "the README documents ${name}" "| \`${name}\`" "${readme}"
	used=$(grep -rl "${name}" "${root}/lib" "${root}/bin" "${root}/adapters" | head -1 || true)
	check "the code uses ${name}" yes "$([ -n "${used}" ] && echo yes || echo no)"
done
check_absent "the README no longer says only FreeBSD is written" \
	"Only FreeBSD is written" "${readme}"
check_absent "the README no longer lists the graphical front end as missing" \
	"- The graphical front end.  \`gui/README.md\` lists the pages it will have." "${readme}"
check_absent "gui/README.md no longer says the front end is planned" \
	"is not part of this repository yet" "${gui}"
for page in Welcome Keyboard 'Time zone' Disk Users Network Summary Installing Finished; do
	check_contains "gui/README.md describes the page ${page}" "| ${page} |" "${gui}"
done
check_contains "gui/README.md says the layout is applied to the live session" \
	"setxkbmap" "${gui}"
check_absent "the README names no file of the password itself" "USER_PASSFILE" "${readme}"
check_absent "AGENTS.md names no file of the password itself" "USER_PASSFILE" "${agents}"
check_absent "the README names no rule for the launcher" \
	"cmd /usr/local/bin/wtfbsd-installer" "${readme}"
check "the README gives the sudo rule a secure_path" yes \
	"$(grep -qxF '   Defaults!/usr/local/libexec/wtfbsd-installer/installer-apply env_reset, !setenv, secure_path=/sbin:/bin:/usr/sbin:/usr/bin' \
		"${root}/README.md" && echo yes || echo no)"
check_absent "the doas line has no keepenv" "keepenv live" "${readme}"
check_contains "AGENTS.md names the root helper" "bin/installer-apply" "${agents}"
check_contains "AGENTS.md names the graphical front end" "bin/installer-gui" "${agents}"

finish

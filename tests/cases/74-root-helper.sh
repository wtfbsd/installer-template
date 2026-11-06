#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The root helper (installer-apply) is the only part of the installer that
# runs as root.  It accepts only its fixed verbs; as root it replaces the
# environment, so no variable of the caller has an effect; it reads the
# directory of the front end without following a link and only files of
# the user that asked; it checks every answer again before the
# installation; and a stopped installation ends with a failure even when
# the install command says it ended well.
#
# "As root" is tested with WTFBSD_TEST_AS_ROOT=yes: the helper reads it only
# when /usr/bin/id does not say 0, and then takes the branch of root, and
# everything it does from there is checked.  (The other scripts of the
# installer still take an id(1) on PATH that says 0 for root, see
# lib/rootguard.sh: it can only drop the overrides.)

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-helper.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'chmod -R u+rwX "${tmp}" 2>/dev/null || :; rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

helper="${root}/bin/installer-apply"
stubs="${root}/tests/stubs"
fixture="${root}/tests/fixtures/adapter-fixture.conf"
NL='
'

# ------------------------------------------------------------- the verbs
for args in '' '--bogus' '--list' '--list secrets' '--list disks extra' \
	'--install' '--install a b' '--reboot now' '--smoke x' '--list ../../etc'; do
	rc=0
	# shellcheck disable=SC2086
	out=$(INSTALLER_ADAPTER_FIXTURE="${fixture}" "${helper}" ${args} 2>&1) || rc=$?
	check_rc "the helper refuses '${args}'" 2 "${rc}"
	check_contains "the refusal of '${args}' is an ERROR line" "ERROR " "${out}"
done
out=$(INSTALLER_ADAPTER_FIXTURE="${fixture}" "${helper}" --list disks)
check_contains "--list disks prints the disks" '"name":"ada0"' "${out}"
for list in network keymaps timezones users welcome; do
	rc=0
	INSTALLER_ADAPTER_FIXTURE="${fixture}" "${helper}" --list "${list}" >/dev/null 2>&1 || rc=$?
	check_rc "--list ${list} works" 0 "${rc}"
done
check "the helper imports no GTK" "" \
	"$(grep -nE 'import gi|from gi|Gtk' "${root}/lib/apply.py" "${helper}" || true)"

# -------------------------------------------- the directory of the front end
# submit <dir> — a directory the way a front end writes it.
submit() {
	rm -rf "$1"
	mkdir -m 700 "$1"
	printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "$1/user.hash"
	cat > "$1/answers.conf" <<ANSWERS
KEYMAP=us
TIMEZONE=UTC
DISK=ada0
USER_NAME=tester
USER_FULLNAME=Test User
USER_AUTH=password
USER_HASHFILE=/etc/master.passwd
HOSTNAME=box1
PRIVILEGE_PASSWORDLESS=no
NETWORK_MODE=dhcp
NET_IF=em0
ANSWERS
	chmod 600 "$1/answers.conf"
}

# install_from <dir> [VAR=value...] — run the helper on a directory with
# the stand-in install command; the output in out, the code in rc.
install_from() {
	_dir=$1
	shift
	rm -f "${tmp}/args" "${tmp}/hash-copy"
	rc=0
	out=$(env PATH="${stubs}:${PATH}" STUB_MOUNTS="${tmp}/mounts" STUB_DISKS='ada0 ada1' \
		STUB_DISK_INFO="${tmp}/disk-info" STUB_INTERFACES='em0' \
		STUB_INSTALL_ARGS="${tmp}/args" STUB_INSTALL_HASH_COPY="${tmp}/hash-copy" \
		"$@" "${helper}" --install "${_dir}" < /dev/null 2>&1) || rc=$?
}
printf '/dev/ada1p3 / ufs rw 0 0\n' > "${tmp}/mounts"
printf 'ada0\tSamsung SSD 860\t500107862016\nada1\tSamsung SSD 870\t1000204886016\n' \
	> "${tmp}/disk-info"

dir="${tmp}/submit"
submit "${dir}"
install_from "${dir}"
check_rc "a good directory is installed" 0 "${rc}"
check_contains "the PROGRESS lines are on standard output" "PROGRESS 100 Done" "${out}"
hash_arg=$(awk 'prev == "-H" { print } { prev = $0 }' "${tmp}/args" 2>/dev/null || true)
check_absent "the install command gets a copy of the hash, not the file of the user" \
	"${dir}" "${hash_arg}"
check_absent "the hash path of the answers is never used" "/etc/master.passwd" "${hash_arg}"
check "the copy holds the hash of the front end" "$(cat "${dir}/user.hash")" \
	"$(cat "${tmp}/hash-copy" 2>/dev/null || true)"
# The private copy is the directory of the hash the install command got:
# it is gone afterwards, and it was made in a private directory of the
# user (mode 0700), never in a directory everybody may write.
work_dir=${hash_arg%/*}
check "the private copy is gone afterwards" no \
	"$([ -n "${hash_arg}" ] && [ -e "${work_dir}" ] && echo yes || echo no)"
check "the private copy was made in a directory nobody else may enter" 700 \
	"$(stat -c %a "${work_dir%/*}" 2>/dev/null || stat -f %Lp "${work_dir%/*}" 2>/dev/null || echo none)"
check_absent "the private copy was not made in /tmp" "/tmp/wtfbsd-apply." "${hash_arg}"

# refused <name> — the helper refused the directory and the install command
# never ran.
refused() {
	check "${1}: refused" 2 "${rc}"
	check "${1}: the install command never ran" no \
		"$([ -f "${tmp}/args" ] && echo yes || echo no)"
	check_contains "${1}: an ERROR line says why" "ERROR " "${out}"
}

submit "${dir}"; mv "${dir}/user.hash" "${tmp}/real.hash"
ln -s "${tmp}/real.hash" "${dir}/user.hash"
install_from "${dir}"; refused "a hash file that is a link"
submit "${dir}"; mv "${dir}/answers.conf" "${tmp}/real.answers"
ln -s "${tmp}/real.answers" "${dir}/answers.conf"
install_from "${dir}"; refused "an answers file that is a link"
submit "${dir}"; rm -f "${dir}/user.hash"; mkfifo "${dir}/user.hash"
install_from "${dir}"; refused "a hash file that is not a regular file"
submit "${dir}"; chmod 644 "${dir}/user.hash"
install_from "${dir}"; refused "a hash file that others may read"
submit "${dir}"; chmod 664 "${dir}/answers.conf"
install_from "${dir}"; refused "an answers file that others may write"
submit "${dir}"; chmod 777 "${dir}"
install_from "${dir}"; refused "a directory that others may write"
submit "${dir}"; ln -s "${dir}" "${tmp}/dirlink"
install_from "${tmp}/dirlink"; refused "a directory that is a link"
install_from "submit"; refused "a relative directory"
submit "${dir}"; rm -f "${dir}/user.hash"
install_from "${dir}"; refused "no hash file"

# Files of another user: the helper is told that another user asked.
submit "${dir}"
rc=0
out=$(WTFBSD_APPLY_MODE=user WTFBSD_INVOKER_UID=$(( $(id -u) + 1 )) \
	python3 -I -B "${root}/lib/apply.py" --install "${dir}" 2>&1) || rc=$?
check_rc "files of another user than the one that asked are refused" 2 "${rc}"
check_contains "the refusal names the owner" "does not belong to the user that asked" "${out}"

# Every answer is checked again.
answer() { # answer <name> <sed expression>
	submit "${dir}"
	sed -e "$2" "${dir}/answers.conf" > "${dir}/a.new"
	mv "${dir}/a.new" "${dir}/answers.conf"
	chmod 600 "${dir}/answers.conf"
	install_from "${dir}"
	refused "$1"
}
answer "an answer the installer does not know" '$a\
EVIL=1'
answer "an answer given twice" '$a\
DISK=ada0'
answer "an account without a password" 's/USER_AUTH=password/USER_AUTH=none/'
answer "the disk of the running system" 's/DISK=ada0/DISK=ada1/'
answer "a disk that is not there" 's/DISK=ada0/DISK=ada7/'
answer "a name the system uses" 's/USER_NAME=tester/USER_NAME=root/'
answer "a name with a shell character" 's/USER_NAME=tester/USER_NAME=a;id/'
answer "a full name with a colon" 's/USER_FULLNAME=Test User/USER_FULLNAME=x: admin/'
answer "a host name that is not one" 's/HOSTNAME=box1/HOSTNAME=-x-/'
answer "a time zone the system does not have" 's|TIMEZONE=UTC|TIMEZONE=../../etc/passwd|'
answer "a keyboard layout the system does not have" 's/KEYMAP=us/KEYMAP=zz/'
answer "an adapter name that is not one" 's/NET_IF=em0/NET_IF=em0;id/'
answer "a manual address that is not IPv4" 's/NETWORK_MODE=dhcp/NETWORK_MODE=static\
NET_IPV4=static\
IPV4_ADDR=192.0.2.300\
IPV4_MASK=255.255.255.0/'
submit "${dir}"
printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write bcrypt "${tmp}/b.hash" 2>/dev/null &&
	cp "${tmp}/b.hash" "${dir}/user.hash" && chmod 600 "${dir}/user.hash"
install_from "${dir}"; refused "a hash of another scheme than the one of the system"
submit "${dir}"; printf 'not a hash\n' > "${dir}/user.hash"; chmod 600 "${dir}/user.hash"
install_from "${dir}"; refused "a hash file that holds no hash"

# Root's password and the Wi-Fi network are checked like the user's hash.
submit "${dir}"
printf 'ROOT_MODE=password\n' >> "${dir}/answers.conf"
install_from "${dir}"; refused "root with a password and no root hash"
submit "${dir}"
printf 'ROOT_MODE=password\n' >> "${dir}/answers.conf"
printf 'plain-text\n' > "${dir}/root.hash"; chmod 600 "${dir}/root.hash"
install_from "${dir}"; refused "a root hash file that holds no hash"
# A root hash that only starts like one, and a second line after a short
# first one: the helper checks the whole file itself, one line, the full
# pattern of the scheme (the users section checks the same).
submit "${dir}"
printf 'ROOT_MODE=password\n' >> "${dir}/answers.conf"
printf '$6$notahash\n' > "${dir}/root.hash"; chmod 600 "${dir}/root.hash"
install_from "${dir}"; refused "a root hash that only starts with \$6\$"
submit "${dir}"
printf 'ROOT_MODE=password\n' >> "${dir}/answers.conf"
printf '$6$x\nsecond line\n' > "${dir}/root.hash"; chmod 600 "${dir}/root.hash"
install_from "${dir}"; refused "a root hash file of two lines"
# The users section on its own checks the same: the whole file, one line,
# the full pattern of the scheme (for the account and for root).
for bad in '$6$notahash' "$(printf '$6$x\nsecond line')"; do
	printf '%s\n' "${bad}" > "${tmp}/bad.hash"; chmod 600 "${tmp}/bad.hash"
	submit "${dir}"
	sed "s|^USER_HASHFILE=.*|USER_HASHFILE=${dir}/user.hash|" "${dir}/answers.conf" > "${tmp}/u.conf"
	printf 'ROOT_MODE=password\nROOT_HASHFILE=%s\n' "${tmp}/bad.hash" >> "${tmp}/u.conf"
	rc=0
	INSTALLER_ANSWERS="${tmp}/u.conf" INSTALLER_ADAPTER_FIXTURE="${fixture}" \
		"${root}/sections.d/users.sh" validate >/dev/null 2>&1 || rc=$?
	check_rc "the users section refuses root's hash $(printf '%s' "${bad}" | head -n 1)$(printf '%s' "${bad}" | sed -n '2s/.*/ and a second line/p')" 2 "${rc}"
	sed "s|^USER_HASHFILE=.*|USER_HASHFILE=${tmp}/bad.hash|" "${dir}/answers.conf" > "${tmp}/u.conf"
	rc=0
	INSTALLER_ANSWERS="${tmp}/u.conf" INSTALLER_ADAPTER_FIXTURE="${fixture}" \
		"${root}/sections.d/users.sh" validate >/dev/null 2>&1 || rc=$?
	check_rc "the users section refuses the account's hash $(printf '%s' "${bad}" | head -n 1)" 2 "${rc}"
done
submit "${dir}"
printf 'ROOT_MODE=sometimes\n' >> "${dir}/answers.conf"
install_from "${dir}"; refused "a root mode that is not one"
submit "${dir}"
printf '{"if":"iwm0","ssid":"Net","security":"wep","psk":"12345678"}' > "${dir}/wifi.json"
chmod 600 "${dir}/wifi.json"
install_from "${dir}"; refused "a Wi-Fi network with a security that is not offered"
submit "${dir}"
printf 'r00t\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${dir}/root.hash"
printf 'ROOT_MODE=password\nAUTOLOGIN=yes\n' >> "${dir}/answers.conf"
printf '{"if":"iwm0","ssid":"Example Home","security":"wpa2","psk":"correct horse"}' > "${dir}/wifi.json"
chmod 600 "${dir}/wifi.json"
install_from "${dir}"
check_rc "root with a password, autologin and Wi-Fi are installed" 0 "${rc}"
args=$(tr '\n' ' ' < "${tmp}/args" 2>/dev/null || true)
check_contains "the install command gets root's hash" "-r /" "${args}"
check_contains "the install command gets the automatic login" " -A " "${args}"
check_contains "the install command gets the Wi-Fi file" " -W /" "${args}"

# ------------------------------------------------------------- stopping
# An install command that ignores SIGTERM, ends with 0 and says it is done
# when it is told to stop: the run still ends with a failure.
cat > "${tmp}/stubborn-install" <<'STUB'
#!/bin/sh
trap 'echo "PROGRESS 100 Done anyway"; exit 0' TERM
echo "PROGRESS 5 Writing the image"
i=0
while [ "${i}" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
echo "PROGRESS 100 Done"
STUB
chmod +x "${tmp}/stubborn-install"
submit "${dir}"
mkfifo "${tmp}/control"
env PATH="${stubs}:${PATH}" STUB_MOUNTS="${tmp}/mounts" STUB_DISKS='ada0 ada1' \
	STUB_DISK_INFO="${tmp}/disk-info" STUB_INTERFACES='em0' \
	INSTALLER_INSTALL_COMMAND="${tmp}/stubborn-install" \
	sh -c '"$1" --install "$2" < "$3" > "$4" 2>&1; echo $? > "$5"' sh \
	"${helper}" "${dir}" "${tmp}/control" "${tmp}/stop.out" "${tmp}/stop.rc" &
runner=$!
exec 7> "${tmp}/control"
i=0
while [ "${i}" -lt 100 ] && ! grep -q 'PROGRESS 5' "${tmp}/stop.out" 2>/dev/null; do
	sleep 0.1; i=$((i + 1))
done
started=$(date +%s)
printf 'STOP\n' >&7
exec 7>&-
wait "${runner}" || :
i=0
while [ "${i}" -lt 150 ] && [ ! -s "${tmp}/stop.rc" ]; do
	sleep 0.1; i=$((i + 1))
done
took=$(( $(date +%s) - started ))
stop_rc=$(cat "${tmp}/stop.rc" 2>/dev/null || echo none)
check "a stopped installation ends with a failure even when the command says 0" yes \
	"$(case "${stop_rc}" in ''|none|0) echo no ;; *) echo yes ;; esac)"
check_contains "the stop is reported" "ERROR the installation was stopped" \
	"$(cat "${tmp}/stop.out")"
check_absent "the installation did not run to its end" "PROGRESS 100 Done${NL}" \
	"$(cat "${tmp}/stop.out")${NL}"
check "the stop did not wait for the command to finish" yes \
	"$([ "${took}" -lt 8 ] && echo yes || echo no)"

# ------------------------------------------------------------- as root
# A hostile caller: every override of the installer, the variables of the
# loader, of Python and of GTK, and a PATH of its own whose tools leave a
# mark when they run.
evil="${tmp}/evil"
mkdir -p "${evil}/bin" "${evil}/py"
printf '#!/bin/sh\necho 0\n' > "${evil}/bin/id"
for tool in sysctl python3 sh env mount geom diskinfo ifconfig examplebsd-install shutdown; do
	printf '#!/bin/sh\necho %s >> "%s/marks"\nexit 0\n' "${tool}" "${evil}" > "${evil}/bin/${tool}"
done
chmod +x "${evil}/bin/"*
printf 'import os\nopen("%s/marks", "a").write("sitecustomize\\n")\n' "${evil}" > "${evil}/py/sitecustomize.py"
printf 'import os\nopen("%s/marks", "a").write("json\\n")\n' "${evil}" > "${evil}/py/json.py"
cp "${evil}/py/json.py" "${evil}/py/subprocess.py"
printf 'DISKS=evil0|Hostile disk|1\nINTERFACES=evil0\n' > "${evil}/fixture.conf"
printf '#!/bin/sh\necho command >> "%s/marks"\n' "${evil}" > "${evil}/command"
chmod +x "${evil}/command"
preload=''
if command -v cc >/dev/null 2>&1; then
	# A library whose constructor leaves a mark in every process that
	# loads it after the scrub: those processes have HOME=/root, which
	# the caller does not have.
	cat > "${evil}/preload.c" <<CSRC
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void mark(void) {
	const char *home = getenv("HOME");
	if (home && home[0] == '/' && home[1] == 'r' && home[2] == 'o' && home[3] == 'o' && home[4] == 't' && home[5] == 0) {
		FILE *f = fopen("${evil}/marks", "a");
		if (f) { fputs("preload\n", f); fclose(f); }
	}
}
CSRC
	if cc -shared -fPIC -o "${evil}/preload.so" "${evil}/preload.c" 2>/dev/null; then
		preload="${evil}/preload.so"
	fi
fi
[ -n "${preload}" ] || printf 'skip the LD_PRELOAD probe: no C compiler\n'

hostile() { # hostile <helper arguments...> — run the helper as a hostile root caller
	env PATH="${evil}/bin:${PATH}" SUDO_UID="$(id -u)" WTFBSD_TEST_AS_ROOT=yes \
		INSTALLER_ROOT="${evil}" INSTALLER_LIBEXEC="${evil}" INSTALLER_CONF="${evil}/fixture.conf" \
		INSTALLER_ADAPTER_FIXTURE="${evil}/fixture.conf" INSTALLER_INSTALL_COMMAND="${evil}/command" \
		INSTALLER_REBOOT_COMMAND="${evil}/command" BSDDIALOG="${evil}/command" \
		INSTALLER_ZONEINFO="${evil}" INSTALLER_MEDIA_MOUNT=/nonexistent \
		LD_PRELOAD="${preload:-/nonexistent.so}" PYTHONPATH="${evil}/py" PYTHONHOME="${evil}" \
		PYTHONSTARTUP="${evil}/py/json.py" XDG_CONFIG_HOME="${evil}" GTK_MODULES=evil \
		WTFBSD_APPLY_MODE=user WTFBSD_INVOKER_UID=0 \
		"${helper}" "$@" 2>&1
}
: > "${evil}/marks"
out=$(hostile --list disks || :)
check_absent "as root the fixture of the caller is not read" "evil0" "${out}"
check_absent "as root the keymaps of the caller are not read" "evil0" "$(hostile --list keymaps || :)"
submit "${dir}"
out=$(hostile --install "${dir}" < /dev/null || :)
check_contains "as root the install is checked against the machine itself" "ERROR " "${out}"
out=$(hostile --reboot || :)
check_contains "as root without a real root the reboot is refused" "ERROR rebooting needs root" "${out}"
# Nothing of the caller runs: the helper sets its own PATH before it runs
# any command, and the id of the PATH of the caller decides nothing.
marks=$(grep -v '^$' "${evil}/marks" | sort -u | tr '\n' ' ')
check "as root no tool, module, library or command of the caller ran" "" "${marks}"

# sudo with env_reset keeps the PATH of the caller unless secure_path is
# set.  A PATH where every tool a shell script could use leaves a mark (and
# whose id says 0): run the way sudo runs it, nothing of it may run, not
# even before the helper replaces its environment.
sudo_path="${tmp}/sudo-path"
mkdir -p "${sudo_path}"
for tool in dirname basename id cat sed awk grep tr cut head tail env python3 python \
	sh bash dash ls pwd realpath readlink mktemp printf test expr uname stat find \
	rm mv cp chmod chown sort uniq wc xargs date sleep kill true false; do
	printf '#!/bin/sh\necho %s >> "%s/sudo-marks"\necho 0\n' "${tool}" "${tmp}" \
		> "${sudo_path}/${tool}"
done
chmod +x "${sudo_path}/"*
cp "${sudo_path}/test" "${sudo_path}/["
: > "${tmp}/sudo-marks"
submit "${dir}"
for args in '--list disks' '--list users' "--install ${dir}" '--reboot' '--bogus'; do
	# shellcheck disable=SC2086
	(cd "${tmp}" && env PATH="${sudo_path}" SUDO_UID="$(id -u)" SUDO_USER=tester \
		SUDO_COMMAND="${helper}" WTFBSD_TEST_AS_ROOT=yes HOME="${tmp}" \
		/bin/sh -c '"$0" "$@"' "${helper}" ${args} < /dev/null > /dev/null 2>&1) || :
done
check "with the PATH sudo keeps, no tool of the caller runs (not even before the scrub)" "" \
	"$(sort -u "${tmp}/sudo-marks" | tr '\n' ' ')"
first=$(grep -vE '^[[:space:]]*(#|$)' "${helper}" | head -2 | tr '\n' '|')
check "the first lines of the helper that run only set PATH" \
	'caller_path=${PATH-}|PATH=/sbin:/bin:/usr/sbin:/usr/bin; export PATH|' "${first}"
check "the helper runs no id(1) of PATH, only /usr/bin/id" "" \
	"$(grep -nE '(^|[^/a-z])id -u' "${helper}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
check "the helper runs no dirname(1)" "" \
	"$(grep -nE 'dirname' "${helper}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
# $0 without a slash (sh installer-apply in its directory) still finds the
# library.
out=$(cd "${root}/bin" && INSTALLER_ADAPTER_FIXTURE="${fixture}" sh installer-apply --list disks 2>&1 || :)
check_contains "the helper run as 'sh installer-apply' finds its library" '"name":"ada0"' "${out}"

# The directory of the caller: doas and sudo keep it.  Python modules put
# there never run, as root or not, whatever the helper does.
plant="${tmp}/plant"
mkdir -p "${plant}"
for module in json os subprocess re; do
	printf 'open("%s/planted", "a").write("%s\\n")\n' "${plant}" "${module}" > "${plant}/${module}.py"
done
submit "${dir}"
: > "${plant}/planted"
(cd "${plant}" && env PATH="${evil}/bin:${PATH}" SUDO_UID="$(id -u)" WTFBSD_TEST_AS_ROOT=yes \
	"${helper}" --install "${dir}" < /dev/null > /dev/null 2>&1) || :
(cd "${plant}" && env PATH="${evil}/bin:${PATH}" SUDO_UID="$(id -u)" WTFBSD_TEST_AS_ROOT=yes \
	"${helper}" --list disks > /dev/null 2>&1) || :
check "as root no module in the directory of the caller is imported" "" \
	"$(sort -u "${plant}/planted" | tr '\n' ' ')"
: > "${plant}/planted"
(cd "${plant}" && env PATH="${stubs}:${PATH}" STUB_MOUNTS="${tmp}/mounts" STUB_DISKS='ada0 ada1' \
	STUB_DISK_INFO="${tmp}/disk-info" STUB_INTERFACES='em0' \
	"${helper}" --install "${dir}" < /dev/null > /dev/null 2>&1) || :
check "not as root either: no module of the directory of the caller is imported" "" \
	"$(sort -u "${plant}/planted" | tr '\n' ' ')"

# As root the helper leaves the directory of the caller, twice: the shell
# (cd /) before it starts Python, and lib/apply.py (os.chdir) before it
# starts anything.  Each is checked by what a child process sees, in a copy
# of the tree where that child is a stand-in that records its directory.
cwd_tree() { # cwd_tree <dir> — a copy of the installer in <dir>
	rm -rf "$1"
	mkdir -p "$1"
	cp -R "${root}/bin" "${root}/lib" "${root}/sections.d" "${root}/adapters" "$1/"
	cp "${root}/installer.conf" "$1/"
}
# The shell: the child is Python; a stand-in apply.py records where it
# started.
cwd_tree "${tmp}/cwd-sh"
printf 'import os\nopen("%s/cwd-sh.seen", "w").write(os.getcwd() + "\\n")\n' "${tmp}" \
	> "${tmp}/cwd-sh/lib/apply.py"
rm -f "${tmp}/cwd-sh.seen"
(cd "${plant}" && WTFBSD_TEST_AS_ROOT=yes "${tmp}/cwd-sh/bin/installer-apply" --list disks \
	> /dev/null 2>&1) || :
check "as root the helper starts Python in / (cd /), not in the directory of the caller" "/" \
	"$(cat "${tmp}/cwd-sh.seen" 2>/dev/null || echo none)"
# lib/apply.py: the child is the backend; a stand-in records where it ran.
cwd_tree "${tmp}/cwd-py"
printf '#!/bin/sh\npwd -P > "%s/cwd-py.seen"\necho "{\\"section\\":\\"disk\\",\\"disks\\":[]}"\n' \
	"${tmp}" > "${tmp}/cwd-py/bin/installer-backend"
chmod +x "${tmp}/cwd-py/bin/installer-backend"
rm -f "${tmp}/cwd-py.seen"
(cd "${plant}" && WTFBSD_APPLY_MODE=root WTFBSD_INVOKER_UID="$(id -u)" \
	python3 -I -B "${tmp}/cwd-py/lib/apply.py" --list disks > /dev/null 2>&1) || :
check "as root apply.py runs its children in / (os.chdir), not in the directory of the caller" "/" \
	"$(cat "${tmp}/cwd-py.seen" 2>/dev/null || echo none)"

# Who runs the helper is told by id(1) at its absolute path only, and it
# fails closed: an id that fails, prints nothing or prints something that
# is not a number stops the helper before Python ever starts.  The tests
# cannot replace /usr/bin/id, so a copy of the helper names a stand-in at
# the one line that sets id_tool (nothing at run time can change it).
check "the helper names id(1) at one line, by its absolute path" "id_tool=/usr/bin/id" \
	"$(grep -E '^id_tool=' "${helper}")"
cwd_tree "${tmp}/uid"
printf 'import os\nopen("%s/uid.python", "a").write("python\\n")\n' "${tmp}" \
	> "${tmp}/uid/lib/apply.py"
for kind in fails zero-fails empty word missing; do
	case "${kind}" in
		fails) label='exits 1'; printf '#!/bin/sh\nexit 1\n' > "${tmp}/uid/id" ;;
		zero-fails) label='prints 0 and exits 1'; printf '#!/bin/sh\necho 0\nexit 1\n' > "${tmp}/uid/id" ;;
		empty) label='prints nothing'; printf '#!/bin/sh\nexit 0\n' > "${tmp}/uid/id" ;;
		word) label='prints a word'; printf '#!/bin/sh\necho root\n' > "${tmp}/uid/id" ;;
		missing) label='is missing'; rm -f "${tmp}/uid/id" ;;
	esac
	[ ! -f "${tmp}/uid/id" ] || chmod +x "${tmp}/uid/id"
	sed -e "s|^id_tool=.*|id_tool='${tmp}/uid/id'|" "${helper}" > "${tmp}/uid/bin/installer-apply"
	chmod +x "${tmp}/uid/bin/installer-apply"
	rm -f "${tmp}/uid.python"
	for args in '--list disks' '--reboot'; do
		rc=0
		# shellcheck disable=SC2086
		out=$("${tmp}/uid/bin/installer-apply" ${args} < /dev/null 2>&1) || rc=$?
		check_rc "an id that ${label}: the helper refuses ${args}" 2 "${rc}"
		check_contains "an id that ${label}: it says why (${args})" \
			"ERROR cannot tell who is running the helper" "${out}"
	done
	check "an id that ${label}: Python never started" no \
		"$([ -f "${tmp}/uid.python" ] && echo yes || echo no)"
done

# Every Python of the installer runs isolated: python3 is always called
# with -I (no current directory, no directory of the script, no PYTHON*
# variable on the path).
unisolated=$(grep -rnIE 'python3( |$|")' "${root}/bin" "${root}/lib" "${root}/sections.d" \
	"${root}/adapters" "${root}/stage" "${root}/install-into-stage.sh" "${root}/tests" |
	grep -vE 'python3 -I([^A-Za-z0-9]|$)' |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
	grep -vE '/python3( |;|$)|python3 is not installed|for tool in |/bin/python3"|\$\{stub\}/python3|every python3 runs|python3 -I\(| stat python3 date ' || true)
check "every python3 runs with -I" "" "${unisolated}"
# Every Python of the installer writes no byte code either: python3 is
# always called with -B, so no __pycache__ appears in the tree of the
# installer (a live system copies that tree to the target).
nocache=$(grep -rnIE 'python3( |$|")' "${root}/bin" "${root}/lib" "${root}/sections.d" \
	"${root}/adapters" "${root}/stage" "${root}/install-into-stage.sh" "${root}/tests" |
	grep -vE 'python3 -I -B([^A-Za-z0-9]|$)' |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
	grep -vE '/python3( |;|$)|python3 is not installed|for tool in |/bin/python3"|\$\{stub\}/python3|every python3 runs|python3 -I\(|python3 -I -B\(| stat python3 date ' || true)
check "every python3 runs with -B (no byte code in the tree of the installer)" "" "${nocache}"
shebangs=$(grep -rlIE '^#!.*python' "${root}/bin" "${root}/lib" "${root}/sections.d" \
	"${root}/adapters" "${root}/stage" "${root}/tests" 2>/dev/null || true)
check "no script starts Python by a #! line (which cannot pass -I everywhere)" "" "${shebangs}"
others=$(grep -rnIE '(^|[^a-z])(perl|ruby)( |$)|awk -f|^[[:space:]]*\. \./' "${root}/bin" "${root}/lib" \
	"${root}/sections.d" "${root}/adapters" "${root}/stage" "${root}/install-into-stage.sh" |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
check "no perl, ruby, awk -f or relative sourcing on the paths of the installer" "" "${others}"

# Every other entry point drops the overrides for root as well.
mkdir -p "${evil}/sections.d"
printf '#!/bin/sh\necho section >> "%s/marks"\necho "{\\"section\\":\\"disk\\",\\"disks\\":[{\\"name\\":\\"evil0\\"}]}"\n' \
	"${evil}" > "${evil}/sections.d/disk.sh"
chmod +x "${evil}/sections.d/disk.sh"
: > "${evil}/marks"
as_root() { # as_root <command...> — run with an id that says root and the overrides
	env PATH="${evil}/bin:${PATH}" INSTALLER_ROOT="${evil}" INSTALLER_LIBEXEC="${evil}/sections.d" \
		INSTALLER_ADAPTER_FIXTURE="${evil}/fixture.conf" INSTALLER_CONF="${evil}/fixture.conf" \
		INSTALLER_INSTALL_COMMAND="${evil}/command" BSDDIALOG="${evil}/command" \
		INSTALLER_STATE_PARENT="${tmp}/state" INSTALLER_LOG="${tmp}/installer.log" \
		"$@" 2>&1 < /dev/null || :
}
# The id of the evil PATH says 0; the tools of the evil PATH that the
# scripts would use are put out of the way for this part.
rm -f "${evil}/bin/sh" "${evil}/bin/env" "${evil}/bin/python3"
out=$(as_root "${root}/bin/installer-backend" disk probe)
check_absent "as root the backend reads neither the fixture nor the sections of the caller" \
	"evil0" "${out}"
out=$(as_root "${root}/bin/installer-config" get PRODUCT_NAME)
check "as root the configuration of the caller is not read" "ExampleBSD" "${out}"
out=$(as_root "${root}/bin/installer-tui")
check_absent "as root the dialog tool of the caller is not run" "command" \
	"$(cat "${evil}/marks")"
check "as root no section, command or tool of the caller ran" "" \
	"$(grep -v -e '^sysctl$' -e '^mount$' -e '^geom$' -e '^diskinfo$' -e '^ifconfig$' "${evil}/marks" | sort -u | tr '\n' ' ')"

# The same hostile caller as a user that is not root may rehearse: the
# fixture is read (the overrides are for tests and rehearsals only).
out=$(env INSTALLER_ADAPTER_FIXTURE="${evil}/fixture.conf" "${helper}" --list disks 2>&1 || :)
check_contains "a user that is not root may rehearse with a fixture" "evil0" "${out}"

finish

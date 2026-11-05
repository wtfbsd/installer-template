#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installation of every adapter calls the install command of the
# template with the options of the contract, built from the answers, and
# passes its PROGRESS and ERROR lines on.  The stand-in install command
# checks its options the way the real one does.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-adapter-install.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

backend="${root}/bin/installer-backend"
stubs="${root}/tests/stubs"
NL='
'

mkdir -m 700 "${tmp}/secrets"
printf 'pw\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${tmp}/secrets/user.hash"
# A public key of the right shape; the type and the body are put together
# here, so the file does not carry the shape of a real key.
printf '%s %s test\n' ssh-ed25519 "AAAA$(printf 'C3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyForTests')" \
	> "${tmp}/key.pub"
cat > "${tmp}/answers" <<ANSWERS
KEYMAP=de
TIMEZONE=Europe/Berlin
DISK=ada1
USER_NAME=wtfuser
USER_AUTH=password
USER_HASHFILE=${tmp}/secrets/user.hash
HOSTNAME=box1
SSH_KEYFILE=${tmp}/key.pub
NETWORK_MODE=dhcp
ANSWERS

# install <os> [VAR=value...] — run the installation of an adapter; the
# output is left in out and the exit code in rc.
install() {
	_os=$1
	shift
	printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=examplebsd\nOS=%s\n' "${_os}" > "${tmp}/${_os}.conf"
	printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' >> "${tmp}/${_os}.conf"
	rc=0
	out=$(env PATH="${stubs}:${PATH}" INSTALLER_CONF="${tmp}/${_os}.conf" \
		INSTALLER_ANSWERS="${tmp}/answers" STUB_INSTALL_ARGS="${tmp}/args" \
		STUB_INSTALL_HASH_COPY="${tmp}/hash-copy" "$@" \
		"${backend}" install apply 2>/dev/null) || rc=$?
}

for os in freebsd netbsd openbsd dragonfly; do
	rm -f "${tmp}/args" "${tmp}/hash-copy"
	install "${os}"
	check_rc "${os}: the installation succeeds" 0 "${rc}"
	check "${os}: the install command gets the options of the contract" \
		"-d${NL}ada1${NL}-u${NL}wtfuser${NL}-k${NL}${tmp}/key.pub${NL}-H${NL}${tmp}/secrets/user.hash${NL}-n${NL}box1${NL}-z${NL}Europe/Berlin${NL}-K${NL}de${NL}-r${NL}locked${NL}-y${NL}--progress" \
		"$(cat "${tmp}/args" 2>/dev/null || true)"
	check "${os}: the progress lines are passed on unchanged" \
		"PROGRESS 5 Writing the image to ada1${NL}PROGRESS 60 Growing the file system${NL}PROGRESS 90 Writing the first boot configuration${NL}PROGRESS 100 Done" \
		"${out}"
	check "${os}: the install command reads the hash the front end wrote" \
		"$(cat "${tmp}/secrets/user.hash")" "$(cat "${tmp}/hash-copy" 2>/dev/null || true)"
done

# A failure: the ERROR line and the exit code of the install command.
install freebsd STUB_INSTALL_FAIL=5
check_rc "a failed install command passes its exit code on" 5 "${rc}"
check_contains "the ERROR line of the install command is passed on" \
	"ERROR the disk ada1 could not be written" "${out}"
check_absent "a second ERROR line is not added" \
	"failed with exit code" "${out}"

install freebsd STUB_INSTALL_FAIL=4 STUB_INSTALL_SILENT=yes
check_rc "a silent failure passes its exit code on" 4 "${rc}"
check_contains "a silent failure still ends with an ERROR line" \
	"ERROR the install command failed with exit code 4" "${out}"

install freebsd STUB_INSTALL_ROOT_DISK=ada1
check_rc "the install command refuses the disk of the running system" 3 "${rc}"

# The install command of a site may live outside PATH.
install freebsd INSTALLER_INSTALL_COMMAND="${stubs}/examplebsd-install" PATH=/usr/bin:/bin
check_rc "INSTALLER_INSTALL_COMMAND names the install command" 0 "${rc}"

# Without the install command the installation stops with a reason.
printf 'PRODUCT_NAME=ExampleBSD\nPRODUCT_SLUG=nosuchproduct\nOS=freebsd\nDEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\n' \
	> "${tmp}/missing.conf"
rc=0
out=$(INSTALLER_CONF="${tmp}/missing.conf" INSTALLER_ANSWERS="${tmp}/answers" \
	"${backend}" install apply 2>/dev/null) || rc=$?
check_rc "a missing install command exits 3" 3 "${rc}"
check_contains "a missing install command is named" \
	"ERROR the install command nosuchproduct-install is not installed" "${out}"

# Without a hash file, or for an account without a password, the install
# command is not run at all.
sed '/USER_HASHFILE/d' "${tmp}/answers" > "${tmp}/answers-nohash"
cp "${tmp}/answers" "${tmp}/answers.keep"
cp "${tmp}/answers-nohash" "${tmp}/answers"
rm -f "${tmp}/args"
install freebsd
check_rc "no hash file: the installation is refused" 2 "${rc}"
check "no hash file: the install command never ran" "no" \
	"$([ -f "${tmp}/args" ] && echo yes || echo no)"
sed 's/USER_AUTH=password/USER_AUTH=none/' "${tmp}/answers.keep" > "${tmp}/answers"
install freebsd
check_rc "no password: the installation is refused" 2 "${rc}"
check_contains "no password: the reason is given" "needs a password" "${out}"
cp "${tmp}/answers.keep" "${tmp}/answers"

# Optional answers that are empty give no option.
sed -e '/SSH_KEYFILE/d' -e 's/HOSTNAME=box1/HOSTNAME=/' "${tmp}/answers.keep" > "${tmp}/answers"
install freebsd
args=$(tr '\n' ' ' < "${tmp}/args")
check_absent "no key: no -k" "-k " "${args}"
check_absent "an empty host name: no -n" "-n " "${args}"

# The full name, passwordless privilege and the network reach the install
# command (-c, -P, -N), each checked before it is put on the command line.
# with_answers <lines...> — the kept answers with these lines in place of
# the lines of the same keys.
with_answers() {
	cp "${tmp}/answers.keep" "${tmp}/answers"
	for _line in "$@"; do
		grep -v "^${_line%%=*}=" "${tmp}/answers" > "${tmp}/answers.new" || :
		printf '%s\n' "${_line}" >> "${tmp}/answers.new"
		mv "${tmp}/answers.new" "${tmp}/answers"
	done
}
mask=$(printf '%s.%s.%s.%s' 255 255 255 0)

with_answers 'USER_FULLNAME=Test User' 'PRIVILEGE_PASSWORDLESS=yes' 'NET_IF=em0'
install freebsd
check_rc "full name, privilege and DHCP: the installation succeeds" 0 "${rc}"
args=$(cat "${tmp}/args")
check_contains "the full name is passed with -c" "-c${NL}Test User${NL}" "${args}"
check_contains "passwordless privilege is passed with -P" "${NL}-P${NL}" "${args}"
check_contains "DHCP on the chosen adapter is passed with -N" "-N${NL}em0:dhcp${NL}" "${args}"

with_answers 'PRIVILEGE_PASSWORDLESS=no' 'NETWORK_MODE=static' 'NET_IF=em1' \
	'IPV4_ADDR=192.0.2.10' "IPV4_MASK=${mask}" 'IPV4_GW=192.0.2.1'
install openbsd
check_rc "a manual address: the installation succeeds" 0 "${rc}"
args=$(cat "${tmp}/args")
check_contains "a manual address is passed as IF:ADDR/MASK:GW" \
	"-N${NL}em1:192.0.2.10/${mask}:192.0.2.1${NL}" "${args}"
check_absent "no -P without passwordless privilege" "${NL}-P${NL}" "${args}"
check_absent "no -c without a full name" "${NL}-c${NL}" "${args}"

with_answers 'NETWORK_MODE=offline' 'NET_IF=em0'
install netbsd
check_absent "an offline system gets no -N" "-N" "$(cat "${tmp}/args")"

# Values that are not well formed never reach the command line.
refused() { # refused <name> <answer lines...>
	_name=$1
	shift
	with_answers "$@"
	rm -f "${tmp}/args"
	install freebsd
	check_rc "${_name}: refused" 2 "${rc}"
	check "${_name}: the install command never ran" no \
		"$([ -f "${tmp}/args" ] && echo yes || echo no)"
	check_contains "${_name}: an ERROR line says why" "ERROR " "${out}"
}
refused "a full name with a colon" 'USER_FULLNAME=Eve: the admin'
refused "a full name with a control character" "USER_FULLNAME=Eve$(printf '\t')x"
refused "an adapter name with a shell character" 'NET_IF=em0;id'
refused "an adapter name with an upper case letter" 'NET_IF=Em0'
refused "an adapter name that is too long" 'NET_IF=abcdefghijklmnop'
refused "an address out of range" 'NETWORK_MODE=static' 'NET_IF=em0' \
	'IPV4_ADDR=192.0.2.300' "IPV4_MASK=${mask}"
refused "a netmask that is not an address" 'NETWORK_MODE=static' 'NET_IF=em0' \
	'IPV4_ADDR=192.0.2.10' 'IPV4_MASK=24'
refused "a gateway with a suffix" 'NETWORK_MODE=static' 'NET_IF=em0' \
	'IPV4_ADDR=192.0.2.10' "IPV4_MASK=${mask}" 'IPV4_GW=192.0.2.1:x'
refused "a manual address without an adapter" 'NETWORK_MODE=static' \
	'IPV4_ADDR=192.0.2.10' "IPV4_MASK=${mask}"
cp "${tmp}/answers.keep" "${tmp}/answers"

# Root's password, the automatic login, every adapter, IPv6, the resolvers
# and the update after the installation reach the install command.
printf 'r00t\n' | python3 -I -B "${root}/lib/passhash.py" write sha512 "${tmp}/secrets/root.hash"
with_answers 'ROOT_MODE=password' "ROOT_HASHFILE=${tmp}/secrets/root.hash" 'AUTOLOGIN=yes' \
	'NET_IPV4_LIST=em0:dhcp;em1:192.0.2.10/255.255.255.0:192.0.2.1' 'NET_IPV6_LIST=em0:slaac' \
	'DNS_SERVERS=192.0.2.53,2001:db8::53' 'UPDATE_AFTER=yes'
install freebsd
check_rc "root, autologin and every adapter: the installation succeeds" 0 "${rc}"
args=$(cat "${tmp}/args")
for want in "-r${NL}${tmp}/secrets/root.hash" "${NL}-A${NL}" "-N${NL}em0:dhcp${NL}" \
	"-N${NL}em1:192.0.2.10/255.255.255.0:192.0.2.1${NL}" "-6${NL}em0:slaac${NL}" \
	"-D${NL}192.0.2.53${NL}" "-D${NL}2001:db8::53${NL}" "${NL}-U${NL}"; do
	check_contains "the install command gets ${want}" "${want}" "${args}"
done
refused "a resolver that is not an address" 'DNS_SERVERS=192.0.2.53;id'
refused "an IPv6 list that is not one" 'NET_IPV6_LIST=em0:2001:db8::1/200:'
cp "${tmp}/answers.keep" "${tmp}/answers"

finish

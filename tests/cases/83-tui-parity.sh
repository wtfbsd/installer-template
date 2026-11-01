#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The text front end asks what the graphical one asks: the language and
# region (the keyboard layout of its country offered), the hardware clock,
# automatic login, the root account (locked or a password of its own,
# kept as a hash only), IPv6, the DNS servers, the update after the
# installation and, for a Wi-Fi adapter, the network and its passphrase
# (a 0600 file, never an argument).  The install command gets them all.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-tui-parity.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

printf 'ada0\tExample SSD\t500107862016\n' > "${tmp}/disk-info"
printf '/dev/ada1p3 / ufs rw 0 0\n' > "${tmp}/mounts"

BSDDIALOG="${root}/tests/fixtures/fake-bsddialog"
BSDDIALOG_LOG="${tmp}/bsd.log"
BSDDIALOG_STATE="${tmp}/bsd.state"
INSTALLER_STATE_PARENT="${tmp}"
INSTALLER_ANSWERS="${tmp}/answers.conf"
INSTALLER_LOG="${tmp}/installer.log"
PATH="${root}/tests/stubs:${PATH}"
STUB_DISKS='ada0 ada1'
STUB_DISK_INFO="${tmp}/disk-info"
STUB_MOUNTS="${tmp}/mounts"
STUB_INTERFACES='em0'
STUB_LOCALES='en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8'
STUB_INSTALL_ARGS="${tmp}/args"
STUB_INSTALL_ROOT_HASH_COPY="${tmp}/root-hash"
export BSDDIALOG BSDDIALOG_LOG BSDDIALOG_STATE INSTALLER_STATE_PARENT INSTALLER_ANSWERS
export INSTALLER_LOG PATH STUB_DISKS STUB_DISK_INFO STUB_MOUNTS STUB_INTERFACES
export STUB_LOCALES STUB_INSTALL_ARGS STUB_INSTALL_ROOT_HASH_COPY
unset INSTALLER_ADAPTER_FIXTURE INSTALLER_CONF 2>/dev/null || :

cat > "${tmp}/answers.txt" <<'ANSWERS'
# welcome, language and region, layout, time zone, hardware clock, disk,
# user, password twice, privileges with automatic login, root with a
# password (twice), adapter, IPv4, IPv6 manual (address, gateway), DNS,
# update, summary, install, finish.
0
0 de_DE.UTF-8
0
0 UTC
0 local
0 ada0
0 tester
0 s3cret-pass
0 s3cret-pass
0 autologin
0 password
0 r00t-Secret!
0 r00t-Secret!
0 em0
0 dhcp
0 static
0 2001:db8::5/64
0 2001:db8::1
0 192.0.2.53,2001:db8::53
0 update
0
0
0
ANSWERS
tui_run "${tmp}/answers.txt"
check_rc "the text front end installs" 0 "${tui_rc}"
log=$(cat "${BSDDIALOG_LOG}")
check_contains "the language is asked" "Choose the language and region of the system." "${log}"
check_contains "the layout of the country is offered" "$(printf -- '--default-item\tde\t')" "${log}"
answers=$(cat "${INSTALLER_ANSWERS}")
for want in LOCALE=de_DE.UTF-8 CLOCK=local ROOT_MODE=password AUTOLOGIN=yes \
	NET_IPV4_LIST=em0:dhcp NET_IPV6_LIST=em0:2001:db8::5/64:2001:db8::1 \
	DNS_SERVERS=192.0.2.53,2001:db8::53 UPDATE_AFTER=yes; do
	check_contains "the answers hold ${want%%=*}" "${want}" "${answers}"
done
args=$(tr '\n' ' ' < "${tmp}/args")
for want in '-L de_DE.UTF-8' '-Z local' '-A' '-6 em0:2001:db8::5/64:2001:db8::1' \
	'-D 192.0.2.53' '-D 2001:db8::53' '-U' '-r /'; do
	check_contains "the install command gets ${want%% *}" " ${want}" " ${args}"
done
check_contains "the disk goes as a plan file" " -p /" " ${args}"
check_absent "not as -d" " -d " " ${args}"
ok=$(printf 'r00t-Secret!\n' | python3 -I -c '
import sys
sys.path.insert(0, sys.argv[2])
import passhash
pw = sys.stdin.readline().rstrip("\n")
h = open(sys.argv[1]).read().strip()
print("yes" if h.startswith("$6$") and passhash.sha512_crypt(pw, h) == h else "no")' \
	"${tmp}/root-hash" "${root}/lib")
check "root gets the hash of its password" yes "${ok}"
for where in "${tmp}/args" "${INSTALLER_ANSWERS}" "${INSTALLER_LOG}"; do
	check_absent "the root password is not in ${where##*/}" "r00t-Secret" "$(cat "${where}" 2>/dev/null || true)"
done

# Root locked is the default, and the hash file goes.
cat > "${tmp}/answers-locked.txt" <<'ANSWERS'
0
0
0
0 UTC
0
0 ada0
0 tester
0 s3cret-pass
0 s3cret-pass
0
0
0 em0
0 dhcp
0
0
0
0
0
0
ANSWERS
tui_run "${tmp}/answers-locked.txt"
check_rc "the default run installs" 0 "${tui_rc}"
answers=$(cat "${INSTALLER_ANSWERS}")
for want in LOCALE=en_US.UTF-8 CLOCK=utc ROOT_MODE=locked AUTOLOGIN=no NET_IPV6_LIST=em0:slaac; do
	check_contains "by default ${want}" "${want}" "${answers}"
done
check_absent "no update unless asked" "UPDATE_AFTER" "${answers}"
check_contains "the install command gets root locked" "-r locked" "$(tr '\n' ' ' < "${tmp}/args")"

# A Wi-Fi adapter (a rehearsal): the network of the scan, its passphrase in
# a 0600 file the root helper checks; never in the answers or the log.
cat > "${tmp}/wifi.conf" <<'CONF'
DISKS=ada0|Example SSD|500107862016
INTERFACES=iwm0|Example Wireless AC
WIFI_SCAN=Example Home|wpa2|82,Open Cafe|open|35
CONF
cat > "${tmp}/answers-wifi.txt" <<'ANSWERS'
0
0 us
0 UTC
0
0 ada0
0 tester
0 s3cret-pass
0 s3cret-pass
0
0
0 iwm0
0 dhcp
0 1
0 Example-Passphrase-1
0
0
0
0
0
0
ANSWERS
unset STUB_LOCALES
INSTALLER_ADAPTER_FIXTURE="${tmp}/wifi.conf" tui_run "${tmp}/answers-wifi.txt"
check_rc "the Wi-Fi run installs" 0 "${tui_rc}"
answers=$(cat "${INSTALLER_ANSWERS}")
check_contains "the answers name the Wi-Fi file" "WIFI_FILE=" "${answers}"
check_contains "the networks of the scan are offered" "Example Home (wpa2, 82%)" "$(cat "${BSDDIALOG_LOG}")"
for where in "${INSTALLER_ANSWERS}" "${INSTALLER_LOG}"; do
	check_absent "the passphrase is not in ${where##*/}" "Example-Passphrase" "$(cat "${where}" 2>/dev/null || true)"
done

# A disk that holds other systems: the summary says so and asks for the
# word; anything else goes back to the summary.  The plan carries the
# confirmation, and the root helper accepts it.
cat > "${tmp}/dual.conf" <<CONF
DISKS=nda0|Example NVMe 980 1TB|1000000000000
DISKS_DETAIL=${root}/tests/fixtures/disks/dual-os.json
INTERFACES=em0|Example Gigabit Ethernet
CONF
cat > "${tmp}/answers-dual.txt" <<'ANSWERS'
0
0 us
0 UTC
0
0 nda0
0 tester
0 s3cret-pass
0 s3cret-pass
0
0
0 em0
0 dhcp
0
0
0
0
0 yes
0
0 ERASE
0
0
ANSWERS
INSTALLER_ADAPTER_FIXTURE="${tmp}/dual.conf" tui_run "${tmp}/answers-dual.txt"
check_rc "the disk with Windows and Debian is erased after the word" 0 "${tui_rc}"
log=$(cat "${BSDDIALOG_LOG}")
check_contains "the summary names what is deleted" "nda0 holds Windows 11, Debian 13: everything on it is deleted." "${log}"
check_contains "the word is asked" "Type erase to confirm." "${log}"
check "a wrong word goes back to the summary" 2 \
	"$(grep -c 'Choose OK to install ExampleBSD with these settings.' "${BSDDIALOG_LOG}")"

finish

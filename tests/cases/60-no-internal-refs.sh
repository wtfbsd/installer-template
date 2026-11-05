#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# This repository is a public template.  It must not carry an address, a name
# or a secret that belongs to somebody else.
#
# The check looks for the shapes that do not belong in a public template and
# never for the name of an organisation: the repository ships no list of
# names.  A site that has names of its own keeps them in a list outside the
# repository and names that list in the environment variable
# WTFBSD_DENYLIST.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

checker="${root}/tests/leak-check.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-leak.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

file_list() { # file_list — the files of the repository, NUL separated
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git ls-files -z --cached --others --exclude-standard
		return 0
	fi
	# Without a working tree the list is built by hand.  The names that the
	# repository ignores are left out, the same way .gitignore leaves them
	# out.
	find . -type f ! -path './.git/*' \
		! -path './state/*' ! -path '*/state/*' \
		! -path '*/__pycache__/*' ! -name '*.pyc' \
		! -name 'ROUND-REPORT*.md' \
		-exec printf '%s\0' {} +
}

count=$(file_list | tr -cd '\000' | wc -c | tr -d ' ')
if [ "${count}" -gt 0 ]; then
	printf 'ok   the repository has %s files to check\n' "${count}"
else
	printf 'FAIL the repository has no files to check\n'
	fails=$((fails + 1))
fi

rc=0
out=$(file_list | xargs -0 "${checker}" 2>&1) || rc=$?
if [ "${rc}" -eq 0 ]; then
	printf 'ok   no shape that does not belong in a public template\n'
else
	printf 'FAIL the repository carries a shape that does not belong in it:\n'
	printf '%s\n' "${out}"
	fails=$((fails + 1))
fi

# Every shape the check looks for has to be found: a file with the shape is
# written, the check has to fail on it and the file is removed again.
probe() { # probe <name> <content>
	file="${root}/probe-${1}.txt"
	printf '%s\n' "$2" > "${file}"
	rc=0
	"${checker}" "${file}" >/dev/null 2>&1 || rc=$?
	rm -f "${file}"
	if [ "${rc}" -ne 0 ]; then
		printf 'ok   the check finds %s\n' "$1"
	else
		printf 'FAIL the check does not find %s\n' "$1"
		fails=$((fails + 1))
	fi
}

probe an-address "$(printf '10.%s.%s.%s' 1 2 3)"
probe an-address-v6 "$(printf 'fe80:%s' ':1')"
probe an-email-address "$(printf 'someone@%s' 'example.net')"
probe a-name-in-an-internal-domain "$(printf 'host.%s' 'corp')"
probe the-header-of-a-private-key "$(printf 'BE%s %sPRIVATE KEY' 'GIN' 'RSA')"
probe the-header-of-a-public-key "$(printf 'ssh-%s AAAA' 'ed25519')"
probe a-token-prefix "$(printf 'gh%s_0123456789abcdef0123' 'p')"
probe a-token-prefix-2 "$(printf 'gh%s_0123456789abcdef0123' 'o')"
probe a-token-prefix-3 "$(printf 'github_p%s_0123456789abcdef' 'at')"
probe a-token-prefix-4 "$(printf '%s%s' 'AKIA' 'IOSFODNN7EXAMPLE')"
probe a-token-prefix-5 "$(printf '%s-%s' 'xoxb' '1234567890abcdefghij')"
probe a-token-prefix-6 "$(printf 'sk-%s' 'abcdefghijklmnopqrstuvwxyz0123')"
probe the-name-of-an-api-key "$(printf 'api%s' 'Key')"
probe a-home-path "$(printf '/ho%s/example' 'me')"
probe an-address-v6-of-digits "$(printf '2001%s470%s1%s%s5' : : : :)"
probe an-address-v6-full "$(printf '1:2:3:4:5:6:%s' '7:8')"
probe a-mac-address "$(printf 'lladdr 02%s63%sbf%s02%s31%sfa' : : : : :)"
probe an-email-of-another-test-domain "$(printf 'root@build.%s' 'example.net')"

# What is not an address: a time, a PCI selector, a MAC of the
# documentation range (RFC 7042), a build line at example.test.
nofind() { # nofind <name> <content>
	file="${root}/probe-${1}.txt"
	printf '%s\n' "$2" > "${file}"
	rc=0
	"${checker}" "${file}" >/dev/null 2>&1 || rc=$?
	rm -f "${file}"
	check "the check lets ${1} pass" 0 "${rc}"
}
nofind a-time "built at 23:24:34 UTC"
nofind a-pci-selector "000:06:0: Example xHCI [xhci0]"
nofind a-documentation-mac "$(printf 'lladdr 00%s00%s5e%s00%s53%s02' : : : : :)"
nofind a-build-line "builder@buildhost1.example.test:/usr/src/sys/arch/amd64/compile/GENERIC"

# A picture: its pixels are not read as text, its text chunks are found.
pic="${tmp}/probe-picture.png"
make_png='
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
if sys.argv[2] == "text":
    png += chunk(b"tEXt", b"Comment\x00made here")
png += chunk(b"IDAT", zlib.compress(b"\x00\x00")) + bytes.fromhex("3a3a313a323a3a") + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
'
python3 -I -B -c "${make_png}" "${pic}" plain
rc=0
"${checker}" "${pic}" >/dev/null 2>&1 || rc=$?
check "the pixels of a picture are not read as text" 0 "${rc}"
python3 -I -B -c "${make_png}" "${pic}" text
rc=0
"${checker}" "${pic}" >/dev/null 2>&1 || rc=$?
check "the text chunk of a picture is found" 1 "${rc}"
rm -f "${pic}"

# The private list of a site: the environment names the file, the repository
# ships no such file.
denylist="${tmp}/denylist.txt"
word=$(printf 'zz%s' 'madeup')
printf '# a comment\n%s\n' "${word}" > "${denylist}"
file="${root}/probe-private-name.txt"
printf 'a %s here\n' "${word}" > "${file}"
rc=0
WTFBSD_DENYLIST="${denylist}" "${checker}" "${file}" >/dev/null 2>&1 || rc=$?
rm -f "${file}"
if [ "${rc}" -ne 0 ]; then
	printf 'ok   the check finds a name of the private list\n'
else
	printf 'FAIL the check does not find a name of the private list\n'
	fails=$((fails + 1))
fi

finish

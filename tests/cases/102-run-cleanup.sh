#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The cleanup of a run removes every temporary file of the run.
#
# The adapter makes a file for the rows of the disks, a file for the
# network, a file for the error marker of the installation, a pipe for the
# output of the install command and a directory for the mark of a
# rehearsal.  Every one of them is named in
# the cleanup, so that a run that is interrupted leaves nothing behind.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installer-cleanup.XXXXXX")
tmp_root=$(dirname "${tmp}")
trap 'rmrf "${tmp}" "${tmp_root}" || :' EXIT INT TERM HUP

# The library of the adapter: the cleanup of the run is in it.
. "${root}/lib/adapter.sh"

# Every kind of temporary file of the run.
work="${tmp}/work"
kept="${tmp}/kept"
install_err="${tmp}/install-err"
install_pipe="${tmp}/install-err.pipe"
disk_rows="${tmp}/disk-rows"
fail_marker_dir="${tmp}/fail-marker"
for file in "${work}" "${kept}" "${install_err}" "${install_err}.seen" \
	"${install_pipe}" "${disk_rows}"; do
	printf 'x\n' > "${file}"
done
mkdir -p "${fail_marker_dir}"

cleanup

gone() { # gone <file> — yes when the file is gone
	if [ -e "$1" ]; then printf 'no\n'; else printf 'yes\n'; fi
}

check "the file of the work of the run is gone" yes "$(gone "${work}")"
check "the file of the rows of the disks is gone" yes "$(gone "${disk_rows}")"
check "the file of the network is gone" yes "$(gone "${kept}")"
check "the file of the error marker of the installation is gone" yes \
	"$(gone "${install_err}")"
check "the mark of the error marker is gone" yes "$(gone "${install_err}.seen")"
check "the pipe of the install command is gone" yes "$(gone "${install_pipe}")"
check "the directory of the mark of the rehearsal is gone" yes \
	"$(gone "${fail_marker_dir}")"

# The cleanup may be called twice: the handler of a signal calls it and
# the trap of the exit calls it again.
work="${tmp}/work"
printf 'x\n' > "${work}"
cleanup
check "the cleanup may be called twice" yes "$(gone "${work}")"

finish

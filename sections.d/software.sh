#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# software: the optional software whose licence the user has to accept.
# The catalogue (licensed-software.json, with the licence texts next to it)
# ships with the template; the adapter says where it is.  Nothing is
# accepted for the user: the answer ACCEPT_LICENSES names what was.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "${here}/.." && pwd)
. "${root}/lib/backend.sh"
. "${root}/lib/config.sh"

verb=${1:-}
if [ $# -ge 1 ]; then
	shift
fi

OS=$(config_value OS) || exit 2

# catalogue — the path of the catalogue, or nothing when the template ships
# none.
catalogue() {
	adapter_cmd licensed-items 2>/dev/null || :
}

cmd_probe() {
	path=$(catalogue)
	CATALOGUE="${path}" LIB="${root}/lib" python3 -I -c '
import json, os, sys
sys.path.insert(0, os.environ["LIB"])
import licensed
path = os.environ["CATALOGUE"]
if not path:
    print(json.dumps({"section": "software", "catalogue": {"items": [], "notices": ""}}))
    sys.exit(0)
try:
    cat = licensed.load(path)
except licensed.CatalogueError as error:
    sys.stderr.write(f"software: {error}\n")
    sys.exit(3)
print(json.dumps({"section": "software", "catalogue": cat}, separators=(",", ":")))
'
}

cmd_validate() {
	accepted=$(answers_get ACCEPT_LICENSES) || accepted=''
	[ -n "${accepted}" ] || return 0
	path=$(catalogue)
	[ -n "${path}" ] || die 2 'licences were accepted and this system has no catalogue'
	CATALOGUE="${path}" ACCEPTED="${accepted}" LIB="${root}/lib" python3 -I -c '
import os, sys
sys.path.insert(0, os.environ["LIB"])
import licensed
try:
    cat = licensed.load(os.environ["CATALOGUE"])
    errors = licensed.check_accepted(cat, licensed.parse_answer(os.environ["ACCEPTED"]))
except licensed.CatalogueError as error:
    errors = [str(error)]
if errors:
    sys.stderr.write("installer-backend: " + "; ".join(errors) + "\n")
    sys.exit(2)
'
}

cmd_apply() {
	:
}

cmd_verify() {
	:
}

case "${verb}" in
	probe) cmd_probe "$@" ;;
	validate) cmd_validate "$@" ;;
	apply) cmd_apply "$@" ;;
	verify) cmd_verify "$@" ;;
	*) die 2 "unknown verb '${verb}' (probe|validate|apply|verify)" ;;
esac

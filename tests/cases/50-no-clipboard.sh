#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The installer offers no way to copy text to the system pasteboard and no
# button that copies.  The documentation may name the rule, the code may not
# use it.

set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${here}/../lib.sh"
root=$(CDPATH= cd "${here}/../.." && pwd)
cd "${root}"

tok1='clip'"board"
tok2='copy'"_button"
tok3='Gtk.'"Clipboard"
tok4='Cop'"ied"
tok5='"Copy"'

for token in "${tok1}" "${tok2}" "${tok3}" "${tok4}" "${tok5}"; do
	hits=$(grep -rIn --exclude-dir=.git --exclude='50-no-clipboard.sh' \
		-- "${token}" bin lib sections.d adapters 2>/dev/null || true)
	check "the installer code does not use ${token}" "" "${hits}"
done

finish

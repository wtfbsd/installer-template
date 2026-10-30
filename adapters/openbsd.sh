#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The OpenBSD adapter is not written yet.  The installer reports the gap
# instead of pretending that it works.

set -eu

printf 'installer-backend: adapter not implemented for openbsd\n' >&2
exit 3

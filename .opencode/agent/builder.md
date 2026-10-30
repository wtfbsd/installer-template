# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

---
description: Implement installer sections, adapters and shell libraries in this repository.
mode: subagent
---

1. Read `AGENTS.md` and `README.md` first.  They carry the overlay rules and
   the contracts; follow them instead of inventing new ones.
2. This repository is the installer core and it has no build script of its
   own.  When a build script is present at the repository root, run it with
   its dry run option first and the real build only when the user asks for
   it.
3. Change one layer at a time.  The product identity belongs in
   `installer.conf`, the system specific work belongs in `adapters/<os>.sh`,
   and the sections and the front end stay generic.
4. Never edit a rule away to make a change fit.  When a rule and a request
   disagree, say so and stop; do not weaken the rule.
5. Write the case that fails before the behaviour exists, then the
   behaviour, then run `tests/run-tests.sh` in the foreground and report
   the result.
6. Every new file carries the licence header.  Every script is POSIX sh
   with `set -eu`, quoted expansions, no `eval` and no global change to IFS.
7. Keep the repository generic.  No organisation name, no host name, no
   address, no ticket number and no credential value.

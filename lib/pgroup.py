# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""pgroup.py <command> [arguments...] - run the command in a process group of
its own.

The adapter starts the install command through this, so that an interrupted
run can stop the command and every process it started with one signal to
the group. The command replaces this process: its process number is the
number of the group.
"""

import os
import sys


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("pgroup.py: no command\n")
        return 2
    try:
        os.setpgid(0, 0)
    except OSError:
        # Already a group leader (or not allowed): the command still runs,
        # and the adapter stops it by its process number.
        pass
    try:
        os.execvp(argv[1], argv[1:])
    except OSError as err:
        sys.stderr.write("pgroup.py: %s: %s\n" % (argv[1], err.strerror))
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv))

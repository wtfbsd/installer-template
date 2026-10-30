# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""Pure answer gating for the installer.

A gated field is used only while the option that controls it is on.  The
gating is a pure function of the answers: it reads no file, writes no file
and never changes the answers it is given.

GATES maps a field to the option that controls it and to the values of that
option that turn the field on.  The order of the table matters: a gate whose
controller is itself gated is evaluated after it, so a nested gate drops
together with its parent.

Every field of the table is a field that the front end of this installer
writes and every controller of the table is a field that the front end
writes.  A gate for a field that nothing writes would hide nothing.
"""

from __future__ import annotations

import sys
from typing import Callable, Dict, List, Mapping, Optional, Set, Tuple

GATES: Dict[str, Tuple[str, Tuple[str, ...]]] = {
    "USER_PASSFILE": ("USER_AUTH", ("password",)),
    "NET_IF": ("NETWORK_MODE", ("dhcp", "static")),
    "NET_IPV4": ("NETWORK_MODE", ("static",)),
    "IPV4_ADDR": ("NET_IPV4", ("static",)),
    "IPV4_MASK": ("NET_IPV4", ("static",)),
    "IPV4_GW": ("NET_IPV4", ("static",)),
}

# SECRET_GATES maps a secret file to the option that allows it to be read
# and to the value that option must have.
SECRET_GATES: Dict[str, Tuple[str, str]] = {
    "USER_PASSFILE": ("USER_AUTH", "password"),
}

USAGE = "usage: gating.py <gate|secrets|gates> [file]"


def gated_answers(answers: Mapping[str, str]) -> Dict[str, str]:
    """A copy of the answers with every field whose gate is off removed."""
    out = dict(answers)
    for field, (controller, values) in GATES.items():
        if out.get(controller) not in values:
            out.pop(field, None)
    return out


def consumed_secrets(answers: Mapping[str, str]) -> Set[str]:
    """The secret files that may be read for these answers.

    A secret is consumed only when its field survived the gating and the
    option that allows it is on.
    """
    gated = gated_answers(answers)
    out: Set[str] = set()
    for name, (controller, value) in SECRET_GATES.items():
        if name not in gated:
            continue
        if gated.get(controller) != value:
            continue
        out.add(name)
    return out


def read_answers(stream) -> Tuple[Dict[str, str], List[str]]:
    """Read KEY=value lines into an ordered mapping."""
    answers: Dict[str, str] = {}
    order: List[str] = []
    for number, raw in enumerate(stream, start=1):
        line = raw.rstrip("\n").rstrip("\r")
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"line {number} is not KEY=value")
        key, value = line.split("=", 1)
        if key not in answers:
            order.append(key)
        answers[key] = value
    return answers, order


def _load(path: Optional[str]) -> Tuple[Dict[str, str], List[str]]:
    """The answers and their order, read from a file or from standard input.

    A file is closed when it is read.  Standard input is read but never
    closed: it belongs to the caller, which may read it again.
    """
    if path is None:
        return read_answers(sys.stdin)
    with open(path, "r", encoding="utf-8") as stream:
        return read_answers(stream)


def _cmd_gates(_path: Optional[str] = None) -> int:
    """Print the gate table.  The table is a constant, so the file is ignored."""
    for field, (controller, values) in GATES.items():
        print(f"{field}\t{controller}\t{','.join(values)}")
    return 0


def _cmd_gate(path: Optional[str]) -> int:
    """Print the answers whose gate is on, in the order of the file."""
    try:
        answers, order = _load(path)
    except (OSError, ValueError) as error:
        print(f"gating: {error}", file=sys.stderr)
        return 2
    gated = gated_answers(answers)
    for key in order:
        if key in gated:
            print(f"{key}={gated[key]}")
    return 0


def _cmd_secrets(path: Optional[str]) -> int:
    """Print the secret files that may be read for these answers."""
    try:
        answers, _order = _load(path)
    except (OSError, ValueError) as error:
        print(f"gating: {error}", file=sys.stderr)
        return 2
    for name in sorted(consumed_secrets(answers)):
        print(name)
    return 0


COMMANDS: Dict[str, Callable[[Optional[str]], int]] = {
    "gates": _cmd_gates,
    "gate": _cmd_gate,
    "secrets": _cmd_secrets,
}


def main(argv: List[str]) -> int:
    """Run one command and return its exit code."""
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    command = argv[0]
    path = argv[1] if len(argv) > 1 else None
    handler = COMMANDS.get(command)
    if handler is None:
        print(USAGE, file=sys.stderr)
        return 2
    return handler(path)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

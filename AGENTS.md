# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

# AGENTS.md

What this repository is, and the rules for changing it.

## What this is

A generic, overlay-configurable BSD installer.  A section dispatch backend in
POSIX sh, a `bsddialog(1)` text front end, a GTK 3 graphical front end
(`bin/installer-gui`, its logic in `lib/wizard.py`), a pure answer-gating
module in Python 3, per-OS adapters that run the install command of the
template, and `install-into-stage.sh` for live images.  The product is a variable: the shipped
configuration calls the product ExampleBSD.

Read `README.md` for the backend contract, the adapter contract and the UX
rules.

## The overlay rules

1. The product identity lives in `installer.conf` only.  Change the name,
   the slug, the system, the default layout or the default time zone there.
2. The system specific work lives in `adapters/<os>.sh`.  Add an adapter;
   do not teach the sections about a system.
3. The sections in `sections.d/` are generic.  A section reads the answers,
   calls the adapter and prints JSON.  It never runs a system command
   itself.
4. The front ends (`bin/installer-tui`, `bin/installer-gui`) never install
   anything themselves.  They drive the backend and write the answers.  A
   decision of the graphical front end lives in `lib/wizard.py`, which
   imports no GTK, so it is tested without a display.
5. A conditional field is gated in `lib/gating.py` only.  The front end may
   hide a field, but the gate decides what reaches the answers file.
6. The configuration file is parsed, never sourced.  No value is ever
   expanded, evaluated or executed.
7. Every new file carries the licence header and every script is POSIX sh
   with `set -eu`, quoted expansions and no `eval`.
8. A destructive command goes through the guarded `rmrf` helper.  It
   refuses an empty path and a path outside its root.
9. The password never reaches a command line or a file.  Both front ends
   hash it in process (`lib/passhash.py`, the password on standard input)
   and write only the hash file (0600 in a 0700 directory), which the
   answer `USER_HASHFILE` names and the install command gets.
10. Only the root helper (`bin/installer-apply`, `lib/apply.py`) runs as
    root.  The front ends run as the user and refuse root for GTK.  The
    helper accepts its fixed verbs only, replaces its environment as root,
    reads the directory of the front end with `O_NOFOLLOW` and checks every
    answer again before it installs.  An override of the environment is
    never honoured for root (`lib/rootguard.sh`, sourced first by every
    script).  The doas or sudo rule names the helper and nothing else.
11. Every Python runs as `python3 -I`; no `#!` line starts Python; no
    perl, ruby, `awk -f` or relative sourcing.  The helper sets its own
    `PATH` before it runs any command, is root only when `/usr/bin/id -u`
    says 0, and leaves the directory of the caller (`cd /`) as root.  The installed tree belongs
    to root: as root by chown, without root through `--metalog`.

## How to build

There is nothing to build: the installer is a set of scripts.  A site copies
`installer.conf` into its own overlay, points `OS` at its adapter and runs
`bin/installer-tui` from the installation media.

## How to test

```sh
tests/run-tests.sh
```

Run it in the foreground and read the whole output.  It needs no root, no
network and no virtual machine.

When a change adds behaviour, add a case under `tests/cases` or a unit test
under `tests/` with it, and show the case failing before the behaviour
exists.

## The generic template rule

This repository is public and anybody must be able to fork it and run it on
their own CI.  So it carries no organisation name, no project name, no host
name, no address, no ticket number, no account name and no credential
value.  Credentials are referenced by a documented generic ID only.

The case `tests/cases/60-no-internal-refs.sh` fails when any file in the
repository carries such a name.  Keep it that way: the test file itself is
written so that it does not carry the names it looks for.

Placeholders only: product ExampleBSD, slug examplebsd, host names
example.org.  Nothing in this repository points at a real machine.

## The agents in this repository

- `.opencode/agent/builder.md` writes sections, adapters and libraries.
- `.opencode/agent/tester.md` runs the test suite and reports the result.

Both are registered in `opencode.json`, which also loads this file for every
agent in the project.

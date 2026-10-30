# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

# AGENTS.md

What this repository is, and the rules for changing it.

## What this is

A generic, overlay-configurable BSD installer.  A section dispatch backend in
POSIX sh, a `bsddialog(1)` text front end, a pure answer-gating module in
Python 3 and per-OS adapter seams.  The product is a variable: the shipped
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
4. The front end in `bin/installer-tui` never installs anything itself.  It
   drives the backend and writes the answers.
5. A conditional field is gated in `lib/gating.py` only.  The front end may
   hide a field, but the gate decides what reaches the answers file.
6. The configuration file is parsed, never sourced.  No value is ever
   expanded, evaluated or executed.
7. Every new file carries the licence header and every script is POSIX sh
   with `set -eu`, quoted expansions and no `eval`.
8. A destructive command goes through the guarded `rmrf` helper.  It
   refuses an empty path and a path outside its root.

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

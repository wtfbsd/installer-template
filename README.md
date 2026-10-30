# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

# installer-template

A generic, overlay-configurable BSD installer:

- a section dispatch backend in POSIX sh,
- a `bsddialog(1)` text front end,
- a pure answer-gating module in Python 3 (standard library only),
- per-OS adapter seams.

The product is a variable.  The shipped configuration calls the product
ExampleBSD; a site changes `installer.conf` and adds an adapter, and the
installer core stays as it is.

## Layout

| Path | What it is |
| --- | --- |
| `bin/installer-backend` | the section dispatcher |
| `bin/installer-config` | reads and validates `installer.conf` |
| `bin/installer-tui` | the text front end |
| `lib/backend.sh` | shared shell helpers (JSON, key/value files, the adapter call) |
| `lib/config.sh` | the configuration parser and its anchored patterns |
| `lib/accounts.sh` | the rules of the first account of the installed system |
| `lib/gating.py` | the pure answer gating |
| `sections.d/*.sh` | one script per installer section |
| `adapters/*.sh` | one script per operating system |
| `installer.conf` | the product configuration |
| `tests/` | the test suite and its fixtures |
| `gui/README.md` | the planned pages of the graphical front end |
| `Jenkinsfile` | the generic CI pipeline |
| `AGENTS.md` | the rules for agents that work in this repository |

## The backend contract

`installer-backend <section> <verb> [arguments...]`

The dispatcher refuses an unknown section or an unknown verb with exit code
2 and says why.  A section name matches `^[a-z][a-z0-9-]*$`.  The dispatcher
runs `sections.d/<section>.sh <verb> [arguments...]` and passes its exit code
on.

| Verb | What it does |
| --- | --- |
| `probe` | read only; prints one JSON object on standard output |
| `validate` | checks the answers; changes nothing |
| `apply` | does the work |
| `verify` | checks that the work was done |

| Exit code | Meaning |
| --- | --- |
| 0 | ok |
| 2 | bad input |
| 3 | environment error |
| 4 | fatal |

| Section | `probe` prints | `apply` and `verify` |
| --- | --- | --- |
| `welcome` | the product name, the slug and the system | nothing |
| `keyboard` | the keyboard layouts and the default | nothing |
| `timezone` | the time zones and the default | nothing |
| `disk` | the disks the adapter offers | the adapter prepares the disk |
| `users` | the accounts | nothing; the install step makes the account |
| `network` | the network adapters the adapter offers | nothing |
| `summary` | the fields the summary page shows | nothing |
| `install` | the steps of the installation | the adapter installs the system |

The section of the accounts checks the answers and it makes no account: the
install step makes the account and it reads the password file that the answer
`USER_PASSFILE` names.  The section of the accounts checks that the file is
there and that the password in it is not empty, and it refuses a name that is
an account of the system that is installed.

## The adapter contract

The operating system specific work goes through `adapters/<os>.sh`.  The
adapter is named by `OS` in `installer.conf`.

| Operation | What it must do |
| --- | --- |
| `disks` | print a JSON array of the disks that may be written to |
| `network` | print a JSON array of the network adapters |
| `apply-disk <disk>` | prepare the disk that was chosen |
| `verify-disk <disk>` | check that the disk was prepared |
| `apply-install` | install the system; print one progress line per step |
| `verify-install` | check that the system was installed |
| `target-root` | print the path of the root of the system that is installed |

Only FreeBSD is written.  The other adapters report
`adapter not implemented for <os>` and exit 3, so an unfinished system is
never mistaken for a working one.

Set `INSTALLER_ADAPTER_FIXTURE` to a KEY=value file to read the hardware from
that file instead of from the machine.  The keys are `DISKS`, `INTERFACES`,
`INSTALL_EXIT`, `INSTALL_FAIL_ONCE` and `TARGET_ROOT`.  `DISKS` and
`INTERFACES` hold a comma separated list of items; an item is the name of the
disk or of the adapter and it may carry a description and a size in bytes after
a bar:

```
DISKS=ada0|Samsung SSD 860|500107862016,ada1|Samsung SSD 870
INTERFACES=em0|Intel I219-LM
INSTALL_EXIT=3
```

`INSTALL_EXIT` is the exit code the rehearsed installation returns; it is 0
when the key is not there.  `INSTALL_FAIL_ONCE=yes` makes the first attempt of
a rehearsal fail and the attempt after it succeed, so that a retry can be
rehearsed.  `TARGET_ROOT` is the path of the root of the system that is
installed; the accounts of that system are read from
`<TARGET_ROOT>/etc/master.passwd`.

A site that rehearses the installer needs no variable in the environment at
all: it puts the same file next to the configuration file of the installer and
calls it `rehearsal.conf`.  The environment variable wins when it is set.

The FreeBSD adapter reads the disks from the machine like this:

- the names come from `sysctl -n kern.disks`,
- the size comes from `diskinfo -v <name>` and, when that is not there, from
  `geom disk list <name>`,
- the description comes from the `descr` line of `geom disk list <name>`.  The
  name of the field is matched without regard to its case,
- the disk that holds the running system and the disk that holds the
  installation media are left out.  The device of the root file system names
  its disk in several ways and every one of them is understood:
  `/dev/ada0p3` is a partition of a GPT disk, `/dev/da0s1a` is a slice of an
  MBR disk with a BSD label, `/dev/ufs/root`, `/dev/gpt/root` and
  `/dev/label/root` are labels whose device is in the list that
  `glabel status -s` prints (the columns are the name, the state and the
  component), and a ZFS root names the pool of the dataset that
  `zfs list -H -o name /` prints, whose devices are the paths that
  `zpool status -P` prints.  The installation media is the file system that is
  mounted on `/mnt`; a site that mounts it elsewhere sets
  `INSTALLER_MEDIA_MOUNT`.

Every text that comes from the machine is reduced to printable ASCII without
a quote and without a backslash before it is put in the JSON, and a disk name
has to match `^[a-z]+[0-9]+$`.

## The configuration

`installer.conf` is KEY=value text.  It is parsed, never sourced: a value is
never expanded, evaluated or executed, and every value is checked against an
anchored pattern before it is used.

| Key | Pattern | Meaning |
| --- | --- | --- |
| `PRODUCT_NAME` | `^[A-Za-z][A-Za-z0-9 ._-]{0,63}$` | the name the installer calls itself |
| `PRODUCT_SLUG` | `^[a-z][a-z0-9-]{0,63}$` | the name used for files and addresses |
| `OS` | `^(freebsd\|netbsd\|openbsd\|dragonfly\|illumos)$` | the system the installer runs on |
| `DEFAULT_KEYMAP` | `^[A-Za-z0-9._-]{1,32}$` | the layout the installer offers first |
| `DEFAULT_TZ` | `^[A-Za-z][A-Za-z0-9+_-]*(/[A-Za-z0-9+_-]+)*$` | the time zone the installer offers first |

`bin/installer-config list`, `bin/installer-config get KEY` and
`bin/installer-config validate` read it.

## The text front end

`bin/installer-tui` shows the pages in this order:

1. welcome
2. keyboard
3. timezone
4. disk
5. users
6. network
7. summary
8. install
9. finish

The rules the front end follows:

- The primary action is the one Enter accepts.  The other button is Back when
  it goes back and Quit when it leaves the installer, and no dialog ever
  starts with the second button focused.
- The dialog tool draws its screen on standard output and writes the choice
  of the user to the file descriptor it is given.  The front end gives it
  `--output-fd 4` and keeps the terminal on file descriptor 3, so the screen
  reaches the terminal and only the choice is read.  A yes or no box writes
  nothing, so it is given no descriptor at all.
- The escape key asks "Quit the installer?".  The buttons of that question
  are Quit and Continue, and only Quit leaves.
- A yes or no box writes nothing: the answer of the user is the exit code of
  the dialog, 0 for yes and 1 for no.  The front end never reads the answer of
  a yes or no box out of the text of the dialog.
- The machine needs a disk to install to and it may have a network adapter.
  When the machine has no disk, the "Unfortunately" screen opens before the
  first page and offers to look for the hardware again or to quit and stay in
  the live system.  When it has no adapter, the same screen offers to go on
  without a network.  Looking for the hardware again looks for it anew.
- The disk and the network page always show.  When the machine has no disk
  or no adapter, the page says so and offers a rescan or a way out instead
  of disappearing.
- A check that fails before the first page opens the "Unfortunately" screen.
  It lists the requirement, what was detected and what is needed.  It offers
  a rescan, an override and Quit, which leaves the installer.  The override
  is only offered when it can help, which is when the machine has a disk to
  install to, and choosing it asks for a confirmation first.  Quitting leaves
  the installer without installing anything.
- The network page asks for the address, the netmask and the gateway when
  the address is a manual one.  The summary shows the three of them, so that
  the user sees the address that will be used before the installation starts.
- A machine without a network adapter can be installed offline: the network
  page offers to continue offline and the choice is written to the answers.
- A failed installation never reaches the finished page.  The failure page
  offers to run the installation again or to go back to the summary, the
  output of the backend goes to the log, and leaving the installer after a
  failure ends with a non zero exit code.  A retry that works is not a
  failure: the run ends well.
- A password field is masked by the dialog tool.  The dialog tool has no
  button that reveals it, so the installer does not pretend to have one.
- The account needs a password unless the user says that the account has
  none.  The name of the account has to match `^[a-z_][a-z0-9_-]{0,31}$` and
  must not be a name the system uses; a name that is not allowed is asked
  again and no name is ever picked by the installer.  The names the system
  uses are in `lib/accounts.sh`.  The name of the account may not be an
  account of the system that is installed either: the file of the accounts of
  that system is read and a name that is in it is refused.  The account
  itself is made by the install step, which reads the password file that the
  answer `USER_PASSFILE` names.
- The installer offers no button that copies text to the system pasteboard
  and no way to use it.

The state of a run lives in a directory of its own: it is made with
`mktemp -d` under `TMPDIR` (or under `INSTALLER_STATE_PARENT`), it is private,
the password of the account is written to a file of its own with `umask 077`
and is never written over an existing file, and the directory is removed when
the run ends.

The mark of a rehearsal that failed once lives in the state directory of the
run, so that a retry of the same run succeeds.  A run that has no state
directory of its own gets a directory of its own for that mark, and that
directory is gone when the run ends: the mark is never left in a path that
everybody shares, because a mark that outlives its run would make a
rehearsal that comes later succeed when it has to fail.

The log of a run is written in that directory, so it is private and it is
never written in a path that everybody shares.  The copy that is kept is made
when the run ends: it is written in a file of its own next to the
destination and is moved into place afterwards, so a link that is in the way
is never followed and never written through.  The destination is the file
that `INSTALLER_LOG` names, or `wtfbsd-installer.log` in the parent
directory of the state (the directory that `TMPDIR` or
`INSTALLER_STATE_PARENT` names).

The answers are written to a KEY=value file that the backend reads.  The
front end exports the name of that file in `INSTALLER_ANSWERS`, so the
backend finds the answers of the run that is going on.  `INSTALLER_ANSWERS`
may name another file when the answers have to survive the run; otherwise the
file lives in the state directory of the run.  Before the answers are written
they go through `lib/gating.py`: a field whose gate is off never reaches the
file, and the secret files that may be read are listed separately.  Every
field of the gate table is a field the front end writes and every controller
of the table is a field the front end writes.

## Environment

Every variable of the environment is optional: the installer works without
any of them.

| Variable | What it does |
| --- | --- |
| `INSTALLER_CONF` | the configuration file to read; it is `installer.conf` in the root of the installer when the variable is not there |
| `INSTALLER_ROOT` | the root of the installer; the scripts find it themselves when the variable is not there |
| `INSTALLER_LIBEXEC` | the directory that holds the sections; it is `sections.d` in the root of the installer when the variable is not there |
| `BSDDIALOG` | the dialog tool to use; it is `bsddialog` when the variable is not there |
| `INSTALLER_LOG` | the file that keeps the log of the run; it is `wtfbsd-installer.log` in the parent directory of the state when the variable is not there |
| `INSTALLER_STATE_PARENT` | the directory that holds the state directory of the run; it is `TMPDIR` or `/tmp` when the variable is not there |
| `INSTALLER_ANSWERS` | the file that holds the answers; it lives in the state directory of the run when the variable is not there |
| `INSTALLER_ADAPTER_FIXTURE` | the file that holds the hardware of a rehearsal instead of the hardware of the machine |
| `INSTALLER_MEDIA_MOUNT` | the path the installation media is mounted on; it is `/mnt` when the variable is not there |
| `WTFBSD_DENYLIST` | the file that holds the names a site keeps out of the repository |
| `TMPDIR` | the directory that holds the temporary files of a run |

## The gating module

`lib/gating.py` is pure: it reads no file, writes no file and never changes
the answers it is given.

- `GATES` maps a field to the option that controls it and to the values of
  that option that turn the field on.
- `gated_answers(answers)` returns a copy of the answers with every field
  whose gate is off removed.  A gate whose controller is itself gated is
  evaluated after it, so a nested gate drops with its parent.
- `consumed_secrets(answers)` returns the secret files that may be read.

The command line is `gating.py gate|secrets|gates [file]`.

## How to test

```sh
tests/run-tests.sh
```

The runner runs every case under `tests/cases` and then the Python unit
tests.  It needs no root, no network and no virtual machine, and it runs on
Linux and on the BSDs.

The text front end is tested with `tests/fixtures/fake-bsddialog`, which
stands in for `bsddialog(1)`: it draws a screen on standard output, writes
the choice of the user to the descriptor given by `--output-fd` (standard
error when the option is not there), logs every call and uses the exit codes
the manual documents (0 ok, 1 cancel, 5 escape, 255 unsuccessful).  A yes or
no box writes nothing, the way the real tool writes nothing: the answer of
the user is the exit code alone.  The log holds the labels of the buttons of
every call and the content of the file that holds the status of the
installation.

The hardware of the machine is read through the stand-ins under
`tests/stubs`: `mount`, `sysctl`, `glabel`, `zfs`, `zpool`, `geom`,
`diskinfo` and `ifconfig`.  They print what the real tools print, so the
adapter is exercised the way it runs on a machine.  A case puts them first in
`PATH` and tells them what the machine looks like.

One case runs the front end the way production runs it: the caller sets no
`INSTALLER_*` variable at all.  The front end has to make the answers file
itself and has to tell the backend where it is.

## Not in this repository

- The graphical front end.  `gui/README.md` lists the pages it will have.
- The virtual machine seam for the media pipeline.  The installer core does
  not start a machine, so it carries no provider and no boot test.

## The generic template rule

This repository is public and anybody must be able to fork it and run it on
their own CI.  So it carries no organisation name, no project name, no
host name, no address, no ticket number, no account name and no credential
value.  Credentials are referenced by a documented generic ID only.

The test case `tests/cases/60-no-internal-refs.sh` looks for the shapes
that do not belong in a public template: an address that is not a
documentation address, an email address that is not at `example.org` or
`example.com`, a name in an internal domain, the header of a private key, a
token of a well known service, the name of an API key and a path of a home
directory.  It never looks for the name of an organisation and the repository
ships no list of names.

A site that has names of its own keeps them in a list outside the repository
and names that list in the environment variable `WTFBSD_DENYLIST`.  Every
non-comment line of that file is a case insensitive expression that is
matched against every file of the repository.  The variable is empty by
default and the repository carries no such file.

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).

# The graphical front end

`bin/installer-gui` is the graphical front end: a full-screen GTK 3 wizard
written in Python 3 with PyGObject and nothing else (`lib/gui.py`, which
`bin/installer-gui` runs with `python3 -I`).  It drives the same
backend (`bin/installer-backend`), the same gating (`lib/gating.py`) and the
same answers file as the text front end, so the two cannot drift apart.

It runs as the user of the session and refuses to run as root: GTK loads
modules and settings that the user of the display controls.  The lists of
the hardware and the installation itself come from the root helper
`installer-apply` (see "Privileges" in `README.md`), which the front end
runs through doas or sudo; Stop writes the line `STOP` to the helper, and
Reboot runs `installer-apply --reboot`.
Everything it decides is in `lib/wizard.py`, which imports no GTK and is
tested without a display (`tests/test_wizard.py`); the drawing is tested on
Xvfb or on the Broadway backend of GTK (`tests/cases/71-gui.sh`).

## The pages

A sidebar lists the nine pages and marks the current one.

| # | Page | What it does | Checked by |
| --- | --- | --- | --- |
| 1 | Welcome | says what the installer does; "Try the live desktop" or "Install <product>" | - |
| 2 | Keyboard | the layouts of the adapter, with a field to test the keyboard; the layout picked is applied to the live X session at once (`setxkbmap`), so the password is typed in it | `keyboard validate` |
| 3 | Time zone | the zone table of the system, with a search field | `timezone validate` |
| 4 | Disk | the disks the adapter offers, with model and size; "Look for disks again"; says that the disk is erased | `disk validate` |
| 5 | Users | full name, user name, password and its confirmation, host name, an optional SSH public key, passwordless sudo and doas | the rules of `lib/accounts.sh`, then `users validate` |
| 6 | Network | the adapters; automatic address, manual address (address, netmask, gateway) or no network | `network validate` |
| 7 | Summary | every answer, and which disk is erased; Install | every section's `validate` |
| 8 | Installing | a progress bar from the `PROGRESS n msg` lines, the step, a Details log; "Stop the installation" | - |
| 9 | Finished | "Reboot" or "Stay in the live system" | - |

Before the first page the checks of the text front end run.  A machine
without a disk, or without a network adapter, gets the "Unfortunately"
screen, which lists the requirement, what was detected and what is needed,
and offers Rescan, Override (only when it can help: no network, but a disk)
and Quit.  Override without a network installs the system offline.

The password is turned into a crypt hash when the Users page is left, in
the scheme the adapter names (`sha512`, `bcrypt` or `bcrypt-2a`), by the
crypt(3) of the system through `lib/passhash.py`.  Only the hash is written,
to a file of mode 0600 in a directory of mode 0700 in the private state of
the run, and the file is removed after every installation run.  A retry
hashes the password of the Users page again.

A failed installation stays on the Installing page with the `ERROR` line of
the install command and the place of the log, and offers Retry and "Back to
the summary".  Stop ends the whole process group of the installation after a
question whose default is to continue.

## The rules

- One action cluster, at the bottom right of every page.  The primary action
  is the rightmost button and the default (Enter); no other button is ever
  the default.
- A question has two buttons and its default is always the safe one:
  Continue for "Quit the installer?" and for "Stop the installation?".
- Escape and closing the window ask "Quit the installer?".
- The Disk and the Network page always show.  Without a disk or an adapter
  they say so and offer to look again instead of disappearing.
- A field that only matters under another option is greyed out while that
  option is off and keeps what was typed (the manual address under Manual
  address); the gating decides what reaches the answers.
- A failed check lists the requirement, what was detected and what is
  needed.
- The installer offers no way to copy text to the pasteboard.
- Every text field of the Users and the Network page is linked to its
  label: the underlined letter (Alt and the letter) moves the focus to the
  field, and a screen reader names the field when it has the focus (the
  labelled-by relation).  `tests/cases/71-gui.sh` checks every field.

## The product

The name comes from `PRODUCT_NAME` of `installer.conf`.  `PRODUCT_LOGO`, an
optional absolute path of an image, is shown above the name in the sidebar
and is the icon of the menu entry.

## Running it

```
installer-gui [--windowed] [--check] [--smoke FILE [--screenshots DIR]]
```

The live image starts it through the launcher `wtfbsd-installer` (see "The
live image" in `README.md`).  Exit code 10 means "Try the live desktop"; the
session helper then leaves the user on the desktop.  When GTK cannot start,
the text front end runs in `xterm` or `xfce4-terminal`.

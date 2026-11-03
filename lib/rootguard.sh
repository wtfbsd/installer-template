# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The overrides of the environment are for tests and rehearsals only.  When
# the installer runs as root, none of them is honoured: every one of them is
# removed from the environment before anything reads it.  Every script of
# the installer sources this file first, by a path it finds from its own
# place, never from the environment.
#
# The user is root when /usr/bin/id says so, or when the id on PATH says so:
# a PATH that lies can only make a user that is not root lose the overrides.

installer_is_root() {
	[ "$(/usr/bin/id -u 2>/dev/null || :)" = 0 ] && return 0
	[ "$(id -u 2>/dev/null || :)" = 0 ] && return 0
	return 1
}

if installer_is_root; then
	unset INSTALLER_ROOT INSTALLER_LIBEXEC INSTALLER_CONF \
		INSTALLER_ADAPTER_FIXTURE INSTALLER_INSTALL_COMMAND \
		INSTALLER_REBOOT_COMMAND INSTALLER_ZONEINFO INSTALLER_KEYMAP_DIR \
		INSTALLER_DMESG_BOOT INSTALLER_REHEARSAL_STEP_SECONDS \
		INSTALLER_MEDIA_MOUNT INSTALLER_LIVE_MEDIUM_FILE BSDDIALOG 2>/dev/null || :
fi

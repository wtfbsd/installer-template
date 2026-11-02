# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# What differs between the systems outside the adapters (install-into-stage.sh
# reads it while an image is built, where no adapter runs).  A system added
# to the installer gets its line here too.
#
#   os_root_group <os>  the name of the group of root (gid 0): wheel on the
#                       BSDs, root on illumos, which has no wheel
#   os_root_gid <os>    its number: 0 on every system the installer knows

os_root_group() {
	case "$1" in
		freebsd|netbsd|openbsd|dragonfly) printf 'wheel\n' ;;
		illumos) printf 'root\n' ;;
		*) return 1 ;;
	esac
}

os_root_gid() {
	case "$1" in
		freebsd|netbsd|openbsd|dragonfly|illumos) printf '0\n' ;;
		*) return 1 ;;
	esac
}

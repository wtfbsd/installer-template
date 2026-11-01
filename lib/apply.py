# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The root helper of the installer (run by bin/installer-apply only).

It runs with python3 -I and imports nothing but the standard library: no
GTK, no PyGObject, nothing from the directory of the caller.  As root its
environment is the clean one installer-apply made; the overrides of the
tests (INSTALLER_*) are honoured only for a user that is not root.

  apply.py --list disks|network|keymaps|timezones|users|welcome
  apply.py --install DIR
  apply.py --reboot

--install reads DIR, which the front end wrote as the user of the session:
answers.conf, user.hash (mode 0600) and an optional ssh_key.pub.  Every file
is opened without following a link, has to be a regular file of the user
that called the helper and may not be writable by anybody else.  The files
are copied into a new directory of mode 0700, every answer is checked
again by the backend sections and by the rules below, and only then is the
installation run.  Its PROGRESS and ERROR lines go to standard output; a
line "STOP" on standard input, or SIGTERM, SIGINT or SIGHUP, ends the whole
process group of the installation, and a stopped installation always ends
with a non-zero exit code.
"""

import os

# As root, the directory of the caller is left before anything else is
# imported or run: doas and sudo keep it, and a file the caller put there
# must never be found.
if os.environ.get("WTFBSD_APPLY_MODE") == "root" or os.geteuid() == 0:
    os.chdir("/")

import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

BASE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BACKEND = os.path.join(BASE, "bin", "installer-backend")

# The PATH of root, fixed here: the one bin/installer-apply sets, never the
# PATH of the environment.  (/usr/pkg is where NetBSD keeps its packages.)
ROOT_PATH = ("/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:"
             "/usr/pkg/sbin:/usr/pkg/bin")

MODE = os.environ.get("WTFBSD_APPLY_MODE", "user")
ROOT_MODE = MODE == "root" or os.geteuid() == 0
try:
    INVOKER = int(os.environ.get("WTFBSD_INVOKER_UID", ""))
except ValueError:
    INVOKER = -1

LISTS = {"disks": "disk", "network": "network", "keymaps": "keyboard",
         "timezones": "timezone", "users": "users", "welcome": "welcome"}

# The answers the front ends write.  The paths of the hash and of the key
# are never taken from the answers: the helper names its own copies.
ANSWER_KEYS = {
    "KEYMAP", "TIMEZONE", "DISK", "USER_NAME", "USER_FULLNAME", "USER_AUTH",
    "USER_HASHFILE", "HOSTNAME", "SSH_KEYFILE", "PRIVILEGE_PASSWORDLESS",
    "NETWORK_MODE", "NET_IF", "NET_IPV4", "IPV4_ADDR", "IPV4_MASK", "IPV4_GW",
}
PATH_KEYS = {"USER_HASHFILE", "SSH_KEYFILE"}
SECTIONS = ("keyboard", "timezone", "disk", "users", "network", "summary")

HASH_PATTERNS = {
    "sha512": re.compile(r"\$6\$(rounds=[0-9]{1,9}\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}"),
    "bcrypt": re.compile(r"\$2b\$[0-9]{2}\$[./A-Za-z0-9]{53}"),
    "bcrypt-2a": re.compile(r"\$2a\$[0-9]{2}\$[./A-Za-z0-9]{53}"),
}
# The files of the directory of the front end, and of the private copy.
ANSWERS_NAME = "answers.conf"
HASH_NAME = "user.hash"
KEY_NAME = "ssh_key.pub"
# As root the private copies live under this directory of root (mode 0700,
# owned by 0, never a link), not under a directory everybody may write.
ROOT_WORK_BASE = "/var/run/wtfbsd-installer"
MAX_ANSWERS = 16 * 1024
MAX_HASH = 512
MAX_KEY = 16 * 1024


class Refused(Exception):
    """The input of the front end cannot be used."""


def error(text):
    sys.stdout.write(f"ERROR {text}\n")
    sys.stdout.flush()


def base_env():
    """The environment of the backend: the clean one as root."""
    env = dict(os.environ)
    for name in ("WTFBSD_APPLY_MODE", "WTFBSD_INVOKER_UID"):
        env.pop(name, None)
    if ROOT_MODE:
        env = {"PATH": ROOT_PATH, "HOME": "/root", "LANG": "C"}
    return env


def run_section(section, verb, env):
    proc = subprocess.run([BACKEND, section, verb], env=env, capture_output=True,
                          text=True, check=False, stdin=subprocess.DEVNULL)
    return proc.returncode, proc.stdout, proc.stderr


# ----------------------------------------------------------- reading


def read_private(dirfd, name, limit, secret, required=True):
    """The content of a file of the directory of the front end, opened
    without following a link and checked on the descriptor."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dirfd)
    except FileNotFoundError:
        if required:
            raise Refused(f"{name} is not there")
        return None
    except OSError as err:
        raise Refused(f"{name} cannot be opened: {err.strerror} (a link is refused)")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Refused(f"{name} is not a regular file")
        if info.st_uid != INVOKER:
            raise Refused(f"{name} does not belong to the user that asked")
        if info.st_mode & 0o022:
            raise Refused(f"{name} may be written by others")
        if secret and info.st_mode & 0o077:
            raise Refused(f"{name} may be read by others")
        if info.st_size > limit:
            raise Refused(f"{name} is too large")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise Refused(f"{name} is too large")
    finally:
        os.close(fd)
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused(f"{name} is not text")


def open_input_dir(path):
    if not os.path.isabs(path):
        raise Refused("the directory must be an absolute path")
    try:
        dirfd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as err:
        raise Refused(f"the directory cannot be opened: {err.strerror} (a link is refused)")
    info = os.fstat(dirfd)
    if info.st_uid != INVOKER:
        os.close(dirfd)
        raise Refused("the directory does not belong to the user that asked")
    if info.st_mode & 0o022:
        os.close(dirfd)
        raise Refused("the directory may be written by others")
    return dirfd


def split_answer_line(number, line):
    """KEY and value of one line of the answers; the line as text is
    checked first."""
    if "\r" in line or "\0" in line:
        raise Refused(f"line {number} of the answers holds a control character")
    if "=" not in line:
        raise Refused(f"line {number} of the answers is not KEY=value")
    return line.split("=", 1)


def check_answer(key, value, answers):
    """One answer, against the answers read before it."""
    if key not in ANSWER_KEYS:
        raise Refused(f"the answer {key!r} is not an answer of the installer")
    if key in answers:
        raise Refused(f"the answer {key} is given twice")
    if len(value) > 255:
        raise Refused(f"the answer {key} is too long")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Refused(f"the answer {key} holds a control character")


def parse_answers(text):
    answers = {}
    for number, line in enumerate(text.split("\n"), start=1):
        if not line or line.startswith("#"):
            continue
        key, value = split_answer_line(number, line)
        check_answer(key, value, answers)
        answers[key] = value
    for key in PATH_KEYS:
        answers.pop(key, None)
    return answers


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)


def private_dir(path, uid, make_parents=False):
    """path as a private directory of uid: made with mode 0700 when it is
    not there, and then a directory (never a link) of uid that nobody else
    may enter.  Refused otherwise."""
    if make_parents:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    except OSError as err:
        raise Refused(f"{path} cannot be made: {err.strerror}")
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise Refused(f"{path} is not a directory (a link is refused)")
    if info.st_uid != uid:
        raise Refused(f"{path} does not belong to uid {uid}")
    if info.st_mode & 0o077:
        raise Refused(f"{path} may be entered by others")
    return path


def user_work_base():
    """The private directory of the user for the copies: XDG_RUNTIME_DIR
    when it is a 0700 directory of the user, else ~/.cache/wtfbsd-installer."""
    uid = os.geteuid()
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if os.path.isabs(runtime):
        try:
            return private_dir(runtime, uid)
        except (Refused, OSError):
            pass
    # Without HOME, the home directory of the password database.
    home = os.environ.get("HOME", "") or os.path.expanduser("~")
    if not os.path.isabs(home):
        raise Refused("no private directory: HOME is not an absolute path")
    return private_dir(os.path.join(home, ".cache", "wtfbsd-installer"), uid,
                       make_parents=True)


def work_base():
    """Where the private copy of the input is made: a directory of root as
    root, a private directory of the user otherwise; never a directory
    everybody may write."""
    if os.geteuid() == 0:
        return private_dir(ROOT_WORK_BASE, 0)
    return user_work_base()


def prepare(src, env):
    """Copy and check the input of the front end; the private directory."""
    dirfd = open_input_dir(src)
    try:
        answers = parse_answers(read_private(dirfd, ANSWERS_NAME, MAX_ANSWERS, False))
        hash_text = read_private(dirfd, HASH_NAME, MAX_HASH, True)
        key_text = read_private(dirfd, KEY_NAME, MAX_KEY, False, required=False)
    finally:
        os.close(dirfd)
    if answers.get("USER_AUTH") != "password":
        raise Refused("the account needs a password (USER_AUTH=password)")
    code, out, _err = run_section("users", "probe", env)
    scheme = "sha512"
    match = re.search(r'"hash_scheme":"([a-z0-9-]+)"', out) if code == 0 else None
    if match and match.group(1) in HASH_PATTERNS:
        scheme = match.group(1)
    crypt_string = hash_text.strip("\n")
    if "\n" in crypt_string or not HASH_PATTERNS[scheme].fullmatch(crypt_string):
        raise Refused(f"{HASH_NAME} is not a {scheme} crypt hash this system accepts")
    try:
        # mkdtemp makes the directory with mode 0700 (less under a umask).
        work = tempfile.mkdtemp(prefix="wtfbsd-apply.", dir=work_base())
    except OSError as err:
        raise Refused(f"the private directory cannot be made: {err.strerror}")
    write_private(os.path.join(work, HASH_NAME), crypt_string + "\n")
    answers["USER_HASHFILE"] = os.path.join(work, HASH_NAME)
    if key_text is not None and key_text.strip():
        write_private(os.path.join(work, KEY_NAME), key_text)
        answers["SSH_KEYFILE"] = os.path.join(work, KEY_NAME)
    write_private(os.path.join(work, ANSWERS_NAME),
                  "".join(f"{k}={v}\n" for k, v in answers.items()))
    return work


# ----------------------------------------------------------- verbs


def do_list(name, env):
    code, out, err = run_section(LISTS[name], "probe", env)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


def do_install(src, env):
    try:
        work = prepare(src, env)
    except Refused as why:
        error(str(why))
        return 2
    try:
        # A rehearsal (never as root) keeps the mark of a failed attempt in
        # the state of the front end, so that a retry of the run succeeds.
        state = work if ROOT_MODE else os.environ.get("INSTALLER_STATE_DIR", work)
        env = dict(env, INSTALLER_ANSWERS=os.path.join(work, ANSWERS_NAME),
                   INSTALLER_STATE_DIR=state)
        for section in SECTIONS:
            code, _out, err = run_section(section, "validate", env)
            if code != 0:
                reason = " ".join(err.split()).replace("installer-backend: ", "")
                error(reason or f"the {section} check failed")
                return 2
        return run_install(env)
    finally:
        shutil.rmtree(work, ignore_errors=True)


# The longest unfinished line of the control channel that is kept.  The
# only command is "STOP"; anything longer is noise and is dropped, so the
# caller cannot make the helper hold more than this.
CONTROL_KEEP = 64


def feed_control(pending, chunk):
    """The control channel: the bytes after the last newline (at most
    CONTROL_KEEP of them) and whether a complete line said STOP."""
    lines = (pending + chunk).split(b"\n")
    asked = any(line.strip() == b"STOP" for line in lines[:-1])
    return lines[-1][-CONTROL_KEEP:], asked


class InstallRun:
    """One run of the install command: its output is passed on line by
    line, and a STOP line on standard input or a signal ends its process
    group (SIGKILL ten seconds later)."""

    def __init__(self, env):
        self.proc = subprocess.Popen([BACKEND, "install", "apply"], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
        self.stopped = False
        self.deadline = None
        self.pending = b""
        self.control = b""
        self.child_open = True
        self.sel = selectors.DefaultSelector()

    def signal_group(self, number):
        try:
            os.killpg(self.proc.pid, number)
        except OSError:
            pass

    def stop(self, *_args):
        if self.stopped:
            return
        self.stopped = True
        self.deadline = time.monotonic() + 10
        self.signal_group(signal.SIGTERM)

    def watch(self):
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, self.stop)
        self.sel.register(self.proc.stdout, selectors.EVENT_READ, "child")
        try:
            self.sel.register(sys.stdin, selectors.EVENT_READ, "control")
        except (ValueError, OSError):
            pass

    def kill_when_late(self):
        if self.deadline is not None and time.monotonic() > self.deadline:
            self.signal_group(signal.SIGKILL)

    def read_child(self):
        """Pass on the complete lines of the child; False at its end."""
        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            self.child_open = False
            self.sel.unregister(self.proc.stdout)
            return False
        self.pending += chunk
        *lines, self.pending = self.pending.split(b"\n")
        for line in lines:
            sys.stdout.write(line.decode("utf-8", "replace") + "\n")
        sys.stdout.flush()
        return True

    def read_control(self):
        chunk = os.read(sys.stdin.fileno(), 4096)
        if not chunk:
            self.sel.unregister(sys.stdin)
            return
        self.control, asked = feed_control(self.control, chunk)
        if asked:
            self.stop()

    def pump(self):
        """One round of the selector."""
        self.kill_when_late()
        for key, _mask in self.sel.select(timeout=0.5):
            if key.data == "child":
                if not self.read_child():
                    break
            else:
                self.read_control()

    def run(self):
        self.watch()
        while self.child_open:
            self.pump()
        if self.pending:
            sys.stdout.write(self.pending.decode("utf-8", "replace") + "\n")
        code = self.proc.wait()
        if self.stopped:
            error("the installation was stopped")
            # A stopped installation never ends well, whatever the child said.
            return code if code != 0 else 1
        return code


def run_install(env):
    return InstallRun(env).run()


def do_reboot():
    if ROOT_MODE:
        if os.geteuid() != 0:
            error("rebooting needs root")
            return 3
        os.execv("/sbin/shutdown", ["shutdown", "-r", "now"])
    command = os.environ.get("INSTALLER_REBOOT_COMMAND", "")
    if not command:
        error("rebooting needs root")
        return 3
    return subprocess.call(command.split())


def main(argv):
    env = base_env()
    if argv[:1] == ["--list"] and len(argv) == 2 and argv[1] in LISTS:
        return do_list(argv[1], env)
    if argv[:1] == ["--install"] and len(argv) == 2:
        if INVOKER < 0:
            error("the user that asked is not known")
            return 2
        return do_install(argv[1], env)
    if argv == ["--reboot"]:
        return do_reboot()
    error("usage: installer-apply --list LIST | --install DIR | --reboot")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

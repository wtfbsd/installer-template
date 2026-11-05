# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The logic of the graphical front end, without a display.

The graphical front end (bin/installer-gui) draws the pages; everything it
decides is decided here, so it can be tested without a display:

- the pages and their order (the order of the text front end),
- the buttons of every page: one cluster, the primary action last,
- the checks before the first page (requirement, detected, needed),
- the checks of every page, which run the same backend sections the text
  front end runs (bin/installer-backend <section> validate),
- the answers, written through lib/gating.py like the text front end,
- the hash of the password (lib/passhash.py), never the password,
- the installation: the backend's "PROGRESS n msg" and "ERROR msg" lines,
  with a stop that ends the whole process group.

Nothing in this module imports GTK.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import stat
import subprocess
import tempfile
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Tuple

import diskplan
import gating
import passhash

# The titles of the time zone and the software, on their pages and in the
# summary.
TIME_ZONE = "Time zone"
ADDITIONAL_SOFTWARE = "Additional software"

# The pages, in the order of the text front end.
PAGES: List[Tuple[str, str]] = [
    ("welcome", "Welcome"),
    ("keyboard", "Keyboard"),
    ("timezone", TIME_ZONE),
    ("type", "Installation type"),
    ("disk", "Disk"),
    ("users", "Users"),
    ("network", "Network"),
    ("software", ADDITIONAL_SOFTWARE),
    ("summary", "Summary"),
    ("install", "Installing"),
    ("finish", "Finished"),
]
PAGE_IDS = [page for page, _title in PAGES]


def shown_pages(os_name: str, detail: Optional[dict]) -> List[str]:
    """The pages of this system: "Installation type" only where the install
    command takes more than one mode (a choice that is not offered is not
    shown)."""
    modes = diskplan.system(os_name, detail)["modes"]
    return [p for p in PAGE_IDS if not (p == "type" and len(modes) < 2)]

# The exit codes of the graphical front end.  The live session reads
# EXIT_TRY_LIVE to drop to the desktop instead of starting the installer
# again.
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_NO_GUI = 3
EXIT_TRY_LIVE = 10

# The files the root helper reads from the directory of the secrets.
ANSWERS_NAME = "answers.conf"
HASH_NAME = "user.hash"
KEY_NAME = "ssh_key.pub"
PLAN_NAME = "plan.json"


def private_dir(path: str, make_parents: bool = False) -> str:
    """path as a private directory of this user: made with mode 0700 when it
    is not there, and then a directory (never a link) of this user that
    nobody else may enter.  OSError otherwise."""
    if make_parents:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(f"{path} is not a directory (a link is refused)")
    if info.st_uid != os.geteuid():
        raise OSError(f"{path} does not belong to this user")
    if info.st_mode & 0o077:
        raise OSError(f"{path} may be entered by others")
    return path


def private_state_parent(env: Dict[str, str]) -> str:
    """Where the state of a run is made when INSTALLER_STATE_PARENT does not
    say: XDG_RUNTIME_DIR when it is a 0700 directory of this user, else
    ~/.cache/wtfbsd-installer; never a directory everybody may write."""
    runtime = env.get("XDG_RUNTIME_DIR", "")
    if os.path.isabs(runtime):
        try:
            return private_dir(runtime)
        except OSError:
            pass
    home = env.get("HOME", "") or os.path.expanduser("~")
    if not os.path.isabs(home):
        raise OSError("no private directory: HOME is not an absolute path")
    return private_dir(os.path.join(home, ".cache", "wtfbsd-installer"), make_parents=True)


@dataclass(frozen=True)
class Action:
    """One button of the action cluster."""

    ident: str
    label: str
    primary: bool = False
    destructive: bool = False


@dataclass
class Failure:
    """A check before the first page that did not pass."""

    requirement: str
    detected: str
    needed: str
    may_override: bool
    kind: str  # "disk" or "network"
    detail: str = ""


@dataclass
class Item:
    """A disk, a network adapter, a layout or a zone."""

    name: str
    descr: str = ""
    size_bytes: int = 0
    search: str = ""


def human_size(size: int) -> str:
    """The size of a disk the way people read it (powers of 1000)."""
    if size <= 0:
        return "unknown size"
    value = float(size)
    for unit in ("bytes", "kB", "MB", "GB", "TB", "PB"):
        if value < 1000 or unit == "PB":
            if unit == "bytes":
                return f"{int(value)} bytes"
            return f"{value:.1f} {unit}" if value < 100 else f"{value:.0f} {unit}"
        value /= 1000
    return f"{size} bytes"


# ------------------------------------------------------------ progress

# re.ASCII: \d is 0 to 9 only, as [0-9] was.
PROGRESS_RE = re.compile(r"^PROGRESS (\d{1,3})(?: (.*))?$", re.ASCII)
ERROR_RE = re.compile(r"^ERROR (.*)$")


def parse_line(line: str) -> Tuple[str, Optional[int], str]:
    """One line of the backend: ("progress", n, msg), ("error", None, msg)
    or ("log", None, line)."""
    text = line.rstrip("\n")
    match = PROGRESS_RE.match(text)
    if match:
        return "progress", min(100, int(match.group(1))), match.group(2) or ""
    match = ERROR_RE.match(text)
    if match:
        return "error", None, match.group(1)
    return "log", None, text


# ------------------------------------------------------------ keymaps

# The console keymap names of the four systems (vt on FreeBSD, wscons on
# NetBSD and OpenBSD, syscons on DragonFly), by their first part, and the
# X keyboard layout and variant that type the same.
XKB_LAYOUTS: Dict[str, Tuple[str, str]] = {
    "us": ("us", ""), "uk": ("gb", ""), "gb": ("gb", ""),
    "de": ("de", ""), "german": ("de", ""), "fr": ("fr", ""), "french": ("fr", ""),
    "es": ("es", ""), "spanish": ("es", ""), "it": ("it", ""), "italian": ("it", ""),
    "pt": ("pt", ""), "portuguese": ("pt", ""), "br": ("br", ""),
    "ch": ("ch", ""), "swiss": ("ch", ""), "sg": ("ch", ""), "sf": ("ch", "fr"),
    "be": ("be", ""), "belgian": ("be", ""), "nl": ("nl", ""), "dutch": ("nl", ""),
    "dk": ("dk", ""), "danish": ("dk", ""), "fi": ("fi", ""), "finnish": ("fi", ""),
    "no": ("no", ""), "norwegian": ("no", ""), "se": ("se", ""), "sv": ("se", ""),
    "swedish": ("se", ""), "pl": ("pl", ""), "polish": ("pl", ""),
    "cz": ("cz", ""), "czech": ("cz", ""), "hu": ("hu", ""), "hungarian": ("hu", ""),
    "ru": ("ru", ""), "russian": ("ru", ""), "ua": ("ua", ""), "ukrainian": ("ua", ""),
    "jp": ("jp", ""), "jp106": ("jp", ""), "japanese": ("jp", ""),
    "gr": ("gr", ""), "greek": ("gr", ""), "is": ("is", ""), "icelandic": ("is", ""),
    "la": ("latam", ""), "latinamerican": ("latam", ""), "tr": ("tr", ""),
    "turkish": ("tr", ""),
}
# The variants named in the rest of a console keymap name.
XKB_VARIANTS = {"dvorak": "dvorak", "colemak": "colemak", "noacc": "nodeadkeys",
                "nodead": "nodeadkeys", "intl": "intl"}


def xkb_for(keymap: str) -> Optional[Tuple[str, str]]:
    """The X layout and variant of a console keymap name, or None when the
    name is not known (us.dvorak.kbd -> us dvorak, german.iso -> de)."""
    parts = keymap.lower().replace(".kbd", "").split(".")
    base = XKB_LAYOUTS.get(parts[0])
    if base is None:
        return None
    layout, variant = base
    for part in parts[1:]:
        if part in XKB_VARIANTS:
            variant = XKB_VARIANTS[part]
    return layout, variant


def setxkbmap_argv(keymap: str) -> Optional[List[str]]:
    """The setxkbmap call that makes the live X session type in the layout
    of a console keymap name, or None when the name has no X layout."""
    mapped = xkb_for(keymap)
    if mapped is None:
        return None
    layout, variant = mapped
    argv = ["setxkbmap", layout]
    if variant:
        argv += ["-variant", variant]
    return argv


# ------------------------------------------------------------ IPv4

def ipv4_valid(text: str) -> bool:
    """Four decimal numbers from 0 to 255."""
    parts = text.split(".")
    if len(parts) != 4:
        return False
    return all(re.fullmatch(r"\d{1,3}", p, re.ASCII) and int(p) <= 255 for p in parts)


HOSTNAME_RE = re.compile(
    r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*")
SSH_KEY_TYPES = (
    "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh" + ".com",
    "sk-ecdsa-sha2-nistp256@openssh" + ".com",
)


def ssh_key_valid(text: str) -> bool:
    """Every line that is not empty and not a comment is a public key."""
    keys = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2 or fields[0] not in SSH_KEY_TYPES:
            return False
        if not re.fullmatch(r"[A-Za-z0-9+/]+=*", fields[1]):
            return False
        keys += 1
    return keys > 0


# ------------------------------------------------------------ backend

class Backend:
    """The backend of the installer: the same scripts the text front end
    runs."""

    def __init__(self, root: str, env: Optional[Dict[str, str]] = None):
        self.root = root
        self.env = dict(os.environ if env is None else env)
        # How a command is run: directly here; the graphical front end runs
        # it in a thread of its own and keeps its window alive meanwhile.
        self.runner = lambda func, *args: func(*args)

    def _run(self, argv: List[str], stdin: Optional[str] = None) -> Tuple[int, str, str]:
        return self.runner(self._run_now, argv, stdin)

    def _run_now(self, argv: List[str], stdin: Optional[str] = None) -> Tuple[int, str, str]:
        try:
            proc = subprocess.run(argv, input=stdin, capture_output=True,
                                  text=True, env=self.env, check=False,
                                  timeout=300)
        except (OSError, subprocess.TimeoutExpired) as error:
            return 3, "", str(error)
        return proc.returncode, proc.stdout, proc.stderr

    def section(self, section: str, verb: str) -> Tuple[int, str, str]:
        return self._run([os.path.join(self.root, "bin", "installer-backend"),
                          section, verb])

    def helper(self) -> List[str]:
        """The root helper, run the way it has to be: through doas or sudo
        (without a password prompt) when it is installed, which is when it
        belongs to root, and directly in a checkout, in a rehearsal, or
        for root itself."""
        path = os.path.join(self.root, "installer-apply")
        if not os.path.exists(path):
            path = os.path.join(self.root, "bin", "installer-apply")
        try:
            owner = os.stat(path).st_uid
        except OSError:
            owner = -1
        if owner == 0 and os.geteuid() != 0:
            for tool in ("doas", "sudo"):
                found = shutil.which(tool, path=self.env.get("PATH"))
                if found:
                    return [found, "-n", path]
        return [path]

    # The lists of the root helper, by the section that makes them.
    HELPER_LISTS = {"software": "software", "hardware": "hardware","disk": "disks", "network": "network", "keyboard": "keymaps",
                    "timezone": "timezones", "users": "users", "welcome": "welcome"}

    def probe(self, section: str) -> Tuple[dict, str]:
        """The JSON of a probe and the message of the backend.  The probe is
        made by the root helper (installer-apply --list), which reads the
        hardware with the rights it needs; the front end has none."""
        code, out, err = self._run(self.helper() + ["--list", self.HELPER_LISTS[section]])
        data: dict = {}
        if code == 0:
            try:
                data = json.loads(out)
            except ValueError:
                err = err or f"the {section} probe did not print JSON"
        return data, " ".join(err.split())

    def config(self, key: str) -> Optional[str]:
        code, out, _err = self._run(
            [os.path.join(self.root, "bin", "installer-config"), "get", key])
        if code != 0:
            return None
        return out.strip()

    def shell_list(self, function: str) -> List[str]:
        """The lines a function of lib/accounts.sh prints: the rules of the
        accounts live in one place for both front ends."""
        script = '. "$1/lib/accounts.sh"; "$2"'
        code, out, _err = self._run(["sh", "-c", script, "sh", self.root, function])
        if code != 0:
            return []
        return [line for line in out.splitlines() if line]


def items_of(data: dict, key: str) -> List[Item]:
    out = []
    for raw in data.get(key, []) or []:
        if not isinstance(raw, dict) or not raw.get("name"):
            continue
        size = raw.get("size_bytes", 0)
        out.append(Item(str(raw["name"]), str(raw.get("descr") or raw["name"]),
                        int(size) if isinstance(size, int) else 0, str(raw.get("search") or "")))
    return out


# ------------------------------------------------------------ the wizard

@dataclass
class Answers:
    """What the pages collect.  The password itself is not kept here: it
    is turned into a hash when the users page is left."""

    keymap: str = ""
    timezone: str = ""
    locale: str = "en_US.UTF-8"
    clock: str = "utc"
    disk: str = ""
    disk_descr: str = ""
    disk_size: int = 0
    user_name: str = ""
    full_name: str = ""
    hostname: str = ""
    ssh_key: str = ""
    privilege_passwordless: bool = False
    network_mode: str = "dhcp"
    net_if: str = ""
    ipv4_addr: str = ""
    ipv4_mask: str = ""
    ipv4_gw: str = ""
    accept_licenses: List[str] = field(default_factory=list)
    root_mode: str = "locked"
    autologin: bool = False
    net_ipv4: Dict[str, str] = field(default_factory=dict)
    net_ipv6: Dict[str, str] = field(default_factory=dict)
    dns: List[str] = field(default_factory=list)
    update_after: bool = False
    wifi: Optional[dict] = None


class Wizard:
    """The state of one run of the graphical front end."""

    def __init__(self, root: str, env: Optional[Dict[str, str]] = None):
        self.root = root
        base_env = dict(os.environ if env is None else env)
        self.state_parent = base_env.get("INSTALLER_STATE_PARENT") or \
            private_state_parent(base_env)
        os.makedirs(self.state_parent, exist_ok=True)
        # mkdtemp makes the directory with mode 0700 (less under a umask).
        self.state = tempfile.mkdtemp(prefix="wtfbsd-installer.", dir=self.state_parent)
        self.secrets = os.path.join(self.state, "secrets")
        self.answers_file = base_env.get("INSTALLER_ANSWERS") or \
            os.path.join(self.state, ANSWERS_NAME)
        self.log_path = os.path.join(self.state, "installer.log")
        self.log_destination = base_env.get("INSTALLER_LOG") or \
            os.path.join(self.state_parent, "wtfbsd-installer.log")
        fd = os.open(self.log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.close(fd)
        base_env["INSTALLER_STATE_DIR"] = self.state
        base_env["INSTALLER_ANSWERS"] = self.answers_file
        self.env = base_env
        self.backend = Backend(root, base_env)
        self.answers = Answers()
        self.hash_file = ""
        self.root_hash_file = ""
        self._hashed_for: Optional[int] = None
        self.installed = False
        self.install_failed = False
        self.applied_keymap = ""
        self.product = self.backend.config("PRODUCT_NAME") or "the system"
        self.os_name = self.backend.config("OS") or "freebsd"
        self.disk_plan: Optional[dict] = None
        self.disk_detail: dict = {"disks": []}
        self.passphrase = ""
        self.confirm_foreign: List[str] = []
        # One installable disk that is blank: "Installation type" is a notice.
        self.single_blank = False
        self.software_catalogue: dict = {"items": [], "notices": ""}
        self.slug = self.backend.config("PRODUCT_SLUG") or "system"
        logo = self.backend.config("PRODUCT_LOGO")
        self.logo = logo if logo and os.path.isfile(logo) else ""
        self.answers.keymap = self.backend.config("DEFAULT_KEYMAP") or "us"
        self.answers.timezone = self.backend.config("DEFAULT_TZ") or "UTC"
        self.answers.hostname = self.slug
        users, _err = self.backend.probe("users")
        self.hash_scheme = users.get("hash_scheme") or "sha512"
        if self.hash_scheme not in passhash.SCHEMES:
            self.hash_scheme = "sha512"
        self.reserved = set(self.backend.shell_list("reserved_user_names"))
        pattern = self.backend.shell_list("user_name_pattern")
        self.user_pattern = re.compile(pattern[0] if pattern else r"^[a-z_][a-z0-9_-]{0,31}$")

    # ------------------------------------------------------- the log

    def log(self, text: str) -> None:
        if not text.strip():
            return
        with open(self.log_path, "a", encoding="utf-8") as stream:
            stream.write(text if text.endswith("\n") else text + "\n")

    def publish_log(self) -> None:
        """Keep the log where it is documented: a file of its own next to
        the destination, moved into place."""
        directory = os.path.dirname(self.log_destination) or "."
        if not os.path.isdir(directory) or not os.path.isfile(self.log_path):
            return
        fd, tmp = tempfile.mkstemp(prefix=".wtfbsd-installer-log.", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out, \
                    open(self.log_path, encoding="utf-8") as src:
                shutil.copyfileobj(src, out)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.log_destination)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def close(self) -> None:
        """The state of the run is gone when the run ends."""
        self.publish_log()
        state = os.path.realpath(self.state)
        parent = os.path.realpath(self.state_parent)
        if state != parent and state.startswith(parent + os.sep) and os.path.isdir(state):
            shutil.rmtree(state, ignore_errors=True)

    # ------------------------------------------------------- hardware

    def disks(self) -> Tuple[List[Item], str]:
        data, err = self.backend.probe("disk")
        if err:
            self.log(err)
        return items_of(data, "disks"), err

    def forget_disks(self) -> None:
        """A new visit of a page reads the disks again; within one visit the
        report is read once (on a slow system it takes minutes)."""
        self._disk_report = None

    def disk_report(self) -> Tuple[dict, str]:
        """The report of the disks the disk page shows (the root helper's
        disk list with its detail), read once per visit of a page."""
        cached = getattr(self, "_disk_report", None)
        if cached is not None:
            return cached
        self._disk_report = self._read_disk_report()
        return self._disk_report

    def _read_disk_report(self) -> Tuple[dict, str]:
        data, err = self.backend.probe("disk")
        if err:
            self.log(err)
        detail = data.get("detail") if isinstance(data.get("detail"), dict) else {}
        if not detail.get("disks"):
            detail = dict(detail, disks=[
                {"name": i.name, "model": i.descr, "size_bytes": i.size_bytes,
                 "health": {"status": "unknown", "summary": "no health data"},
                 "partitions": [], "os": [], "free": []}
                for i in items_of(data, "disks")])
        self.disk_detail = detail
        self.single_blank = diskplan.single_blank(detail)
        return detail, err

    def set_disk_plan(self, plan: dict, detail: dict, passphrase: str = "") -> List[str]:
        """Keep the plan of the disk page; the problems it still has."""
        self.disk_plan = plan
        self.disk_detail = detail
        self.passphrase = passphrase
        first = ""
        if plan.get("mode") == "erase" and plan.get("disks"):
            first = plan["disks"][0]
        elif plan.get("mode") == "alongside":
            first = (plan.get("alongside") or {}).get("disk", "")
        elif plan.get("partitions"):
            first = plan["partitions"][0].get("disk", "")
        disk = diskplan.disk_index(detail).get(first, {})
        self.answers.disk = first
        self.answers.disk_descr = disk.get("model", "")
        self.answers.disk_size = int(disk.get("size_bytes", 0))
        return diskplan.validate(plan, detail, self.os_name)

    def foreign_to_confirm(self) -> List[str]:
        """The disks the plan erases that hold another system."""
        plan = self.disk_plan or {}
        index = diskplan.disk_index(self.disk_detail)
        erased = list(plan.get("disks", [])) if plan.get("mode") == "erase" else []
        erased += [n for pool in plan.get("data", []) for n in pool.get("disks", [])]
        if plan.get("mode") == "manual":
            erased += sorted({p.get("disk") for p in plan.get("partitions", [])})
        return [n for n in erased if diskplan.foreign(index.get(n, {}))]

    def install_problems(self) -> List[str]:
        """What keeps the plan of the Disk page from being installed: no
        plan, or a rule of lib/diskplan.py it breaks.  The typed
        confirmation is asked on the Summary page and is not one of them."""
        if not self.disk_plan:
            return ["no disk plan was made on the Disk page"]
        plan = dict(self.disk_plan, confirm_foreign=self.foreign_to_confirm())
        return diskplan.validate(plan, self.disk_detail, self.os_name)

    def install_allowed(self) -> bool:
        """Install may be chosen: the plan passes and every disk with
        another system on it is confirmed by the typed word."""
        if self.install_problems():
            return False
        return not self.foreign_to_confirm() or bool(self.confirm_foreign)

    # The word to type before a disk holding another system is erased.
    CONFIRM_WORD = "erase"

    def confirm_erase(self, typed: str) -> bool:
        """The typed confirmation of the summary: with the word, every disk
        the plan erases that holds another system is confirmed; without it,
        none is."""
        if typed.strip().lower() == self.CONFIRM_WORD:
            self.confirm_foreign = self.foreign_to_confirm()
            return True
        self.confirm_foreign = []
        return False

    def disk_actions(self) -> List[Tuple[str, str, bool]]:
        if not self.disk_plan:
            return []
        return diskplan.actions(self.disk_plan, self.disk_detail, self.os_name, self.product)

    def software(self) -> Tuple[dict, str]:
        """The catalogue of the optional licensed software."""
        data, err = self.backend.probe("software")
        if err:
            self.log(err)
        cat = data.get("catalogue") if isinstance(data.get("catalogue"), dict) else {}
        return {"items": cat.get("items", []), "notices": cat.get("notices", "")}, err

    def hardware(self) -> List[dict]:
        """The parts of the machine, their drivers and their firmware."""
        data, err = self.backend.probe("hardware")
        if err:
            self.log(err)
        self.hardware_unavailable = [u for u in data.get("unavailable", []) if isinstance(u, str)]
        return [d for d in data.get("devices", []) if isinstance(d, dict)]

    def network_report(self):
        """The adapters, the Wi-Fi networks each sees and whether the
        machine is online."""
        data, err = self.backend.probe("network")
        if err:
            self.log(err)
        wifi = data.get("wifi") if isinstance(data.get("wifi"), dict) else {}
        return items_of(data, "interfaces"), wifi, bool(data.get("online")), err

    def interfaces(self) -> Tuple[List[Item], str]:
        data, err = self.backend.probe("network")
        if err:
            self.log(err)
        return items_of(data, "interfaces"), err

    def apply_keymap(self, keymap: str) -> str:
        """Make the live X session type in the layout that was chosen, so
        the password is typed in that layout.  The result says what was
        done, for the log; nothing is done without setxkbmap."""
        argv = setxkbmap_argv(keymap)
        if argv is None:
            return f"the keymap {keymap} has no X layout; the layout is not changed"
        tool = shutil.which(argv[0], path=self.env.get("PATH"))
        if tool is None:
            return "setxkbmap is not installed; the layout is not changed"
        try:
            proc = subprocess.run([tool] + argv[1:], env=self.env, capture_output=True,
                                  text=True, timeout=20, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            return f"setxkbmap failed: {error}"
        if proc.returncode != 0:
            return f"setxkbmap failed: {' '.join(proc.stderr.split())}"
        self.applied_keymap = keymap
        return "the live session types in " + " ".join(argv[1:])

    def keymaps(self) -> List[Item]:
        data, err = self.backend.probe("keyboard")
        if err:
            # A warning of the backend (a keymap list it could not read).
            self.log(err)
        self.locales = [l for l in data.get("locales", []) if isinstance(l, str)]
        return items_of(data, "layouts")

    def system_locales(self) -> List[str]:
        """The UTF-8 locales of the system (empty when it has no list)."""
        if not hasattr(self, "locales"):
            self.keymaps()
        return list(self.locales)

    def zones(self) -> List[Item]:
        data, err = self.backend.probe("timezone")
        if err:
            self.log(err)
        return items_of(data, "zones")

    def preflight(self) -> List[Failure]:
        """The checks before the first page, the ones of the text front
        end: a disk is needed; a network adapter may be done without."""
        failures = []
        disks, disk_err = self.disks()
        if not disks:
            failures.append(Failure("A disk to install to", "none found", "one disk",
                                    False, "disk", disk_err))
        nets, net_err = self.interfaces()
        if not nets:
            failures.append(Failure("A network adapter", "none found", "one adapter",
                                    bool(disks), "network", net_err))
        return failures

    def override(self, failure: Failure) -> None:
        """Go on without a requirement.  Without an adapter the system is
        installed offline."""
        if failure.kind == "network":
            self.answers.network_mode = "offline"
            self.answers.net_if = ""

    # ------------------------------------------------------- buttons

    def actions(self, page: str, *, failed: bool = False, running: bool = False,
                failure: Optional[Failure] = None) -> List[Action]:
        """The one action cluster of a page.  The primary action is the
        last one, at the right; no other action is the default."""
        if page == "preflight":
            acts = [Action("quit", "Quit")]
            if failure is not None and failure.may_override:
                acts.append(Action("override", "Override"))
            acts.append(Action("rescan", "Rescan", primary=True))
            return acts
        if page == "welcome":
            return [Action("try-live", "Try the live desktop"),
                    Action("next", f"Install {self.product}", primary=True)]
        if page == "summary":
            return [Action("back", "Back"),
                    Action("install", "Install", primary=True, destructive=True)]
        if page == "install":
            if running:
                return [Action("stop", "Stop the installation", primary=True)]
            if failed:
                return [Action("back", "Back to the summary"),
                        Action("retry", "Retry", primary=True)]
            return []
        if page == "hardware":
            return [Action("close", "Close", primary=True)]
        if page == "finish":
            return [Action("stay", "Stay in the live system"),
                    Action("reboot", "Reboot", primary=True)]
        return [Action("back", "Back"), Action("next", "Next", primary=True)]

    def pages(self, read: bool = False) -> List[str]:
        """The pages of this system.  Whether Installation type is one of
        them comes from the install command's modes (the disk report);
        read=True reads the report when it was not read yet."""
        if read and getattr(self, "_disk_report", None) is None:
            self.disk_report()
        return shown_pages(self.os_name, getattr(self, "disk_detail", None) or None)

    def next_page(self, page: str) -> str:
        index = PAGE_IDS.index(page)
        pages = self.pages(read=PAGE_IDS[min(index + 1, len(PAGE_IDS) - 1)] == "type")
        later = [p for p in PAGE_IDS[index + 1:] if p in pages]
        return later[0] if later else PAGE_IDS[-1]

    def prev_page(self, page: str) -> str:
        index = PAGE_IDS.index(page)
        pages = self.pages(read=PAGE_IDS[max(index - 1, 0)] == "type")
        earlier = [p for p in PAGE_IDS[:index] if p in pages]
        return earlier[-1] if earlier else PAGE_IDS[0]

    # ------------------------------------------------------- users

    def check_user_name(self, name: str) -> Optional[str]:
        if not name:
            return "Type a user name."
        if name in self.reserved:
            return f"The name '{name}' cannot be used: it is a name the system uses."
        if not self.user_pattern.match(name):
            return ("The name cannot be used. A name starts with a lower case letter "
                    "or an underline and holds lower case letters, digits, underlines "
                    "and dashes.")
        return None

    def check_users(self, name: str, full_name: str, password: str, confirm: str,
                    hostname: str, ssh_key: str) -> Dict[str, str]:
        """The fields of the users page that are wrong, with the reason."""
        errors: Dict[str, str] = {}
        problem = self.check_user_name(name)
        if problem:
            errors["user_name"] = problem
        if ":" in full_name or any(ord(c) < 32 for c in full_name) or len(full_name) > 64:
            errors["full_name"] = "The full name may not hold a colon and is at most 64 characters."
        if not password:
            errors["password"] = "Type a password."
        elif "\n" in password:
            errors["password"] = "The password may not hold a line break."
        elif password != confirm:
            errors["confirm"] = "The passwords do not match."
        if hostname and (len(hostname) > 253 or not HOSTNAME_RE.fullmatch(hostname)):
            errors["hostname"] = ("A host name holds letters, digits and dashes, "
                                  "in parts separated by dots.")
        if ssh_key.strip() and not ssh_key_valid(ssh_key):
            errors["ssh_key"] = "This is not an SSH public key (ssh-ed25519, ssh-rsa or ecdsa)."
        return errors

    def set_password(self, password: str) -> None:
        """Hash the password and keep only the hash, in a file of mode 0600
        in a directory of mode 0700.  The same password is not hashed
        again."""
        marker = hash(password)
        if self.hash_file and self._hashed_for == marker and os.path.exists(self.hash_file):
            return
        crypt_string = passhash.make_hash(password, self.hash_scheme)
        path = os.path.join(self.secrets, HASH_NAME)
        passhash.write_hash_file(path, crypt_string)
        self.hash_file = path
        self._hashed_for = marker

    def set_root_password(self, password: str) -> None:
        """Root gets a password of its own: only its hash is kept."""
        path = os.path.join(self.secrets, "root.hash")
        passhash.write_hash_file(path, passhash.make_hash(password, self.hash_scheme))
        self.root_hash_file = path
        self.answers.root_mode = "password"

    def delete_secrets(self) -> None:
        for name in (ANSWERS_NAME, PLAN_NAME, "passphrase", "root.hash", "wifi.json"):
            try:
                os.unlink(os.path.join(self.secrets, name))
            except OSError:
                pass
        if self.hash_file:
            try:
                os.unlink(self.hash_file)
            except OSError:
                pass
        self.hash_file = ""
        self._hashed_for = None

    def _ssh_key_file(self) -> str:
        text = self.answers.ssh_key.strip()
        os.makedirs(self.secrets, mode=0o700, exist_ok=True)
        path = os.path.join(self.secrets, KEY_NAME)
        if not text:
            try:
                os.unlink(path)
            except OSError:
                pass
            return ""
        fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text + "\n")
        os.replace(path + ".tmp", path)
        return path

    # ------------------------------------------------------- answers

    def answers_raw(self) -> List[Tuple[str, str]]:
        """The answers, in the order and with the keys of the text front
        end, before the gating."""
        a = self.answers
        out = [
            ("KEYMAP", a.keymap),
            ("LOCALE", a.locale),
            ("TIMEZONE", a.timezone),
            ("CLOCK", a.clock),
            ("DISK", a.disk),
            ("USER_NAME", a.user_name),
            ("USER_FULLNAME", a.full_name),
            ("USER_AUTH", "password"),
        ]
        if self.hash_file:
            out.append(("USER_HASHFILE", self.hash_file))
        out.append(("HOSTNAME", a.hostname))
        key_file = self._ssh_key_file()
        if key_file:
            out.append(("SSH_KEYFILE", key_file))
        out += [
            ("PRIVILEGE_PASSWORDLESS", "yes" if a.privilege_passwordless else "no"),
            ("NETWORK_MODE", a.network_mode),
            ("NET_IF", a.net_if),
        ]
        if a.network_mode == "static":
            out += [("NET_IPV4", "static"), ("IPV4_ADDR", a.ipv4_addr),
                    ("IPV4_MASK", a.ipv4_mask), ("IPV4_GW", a.ipv4_gw)]
        if a.accept_licenses:
            out.append(("ACCEPT_LICENSES", ",".join(a.accept_licenses)))
        out.append(("ROOT_MODE", a.root_mode))
        if a.root_mode == "password" and self.root_hash_file:
            out.append(("ROOT_HASHFILE", self.root_hash_file))
        out.append(("AUTOLOGIN", "yes" if a.autologin else "no"))
        if a.net_ipv4:
            out.append(("NET_IPV4_LIST", ";".join(f"{k}:{v}" for k, v in a.net_ipv4.items())))
        if a.net_ipv6:
            out.append(("NET_IPV6_LIST", ";".join(f"{k}:{v}" for k, v in a.net_ipv6.items())))
        if a.dns:
            out.append(("DNS_SERVERS", ",".join(a.dns)))
        if a.update_after:
            out.append(("UPDATE_AFTER", "yes"))
        if a.wifi:
            path = os.path.join(self.secrets, "wifi.json")
            os.makedirs(self.secrets, mode=0o700, exist_ok=True)
            try:
                os.unlink(path)
            except OSError:
                pass
            write_new_file(path, json.dumps(a.wifi).encode("utf-8"), 0o600)
            out.append(("WIFI_FILE", path))
        return out

    def write_answers(self) -> None:
        """Write the answers through the gate, like the text front end: a
        field whose gate is off never reaches the file."""
        raw = self.answers_raw()
        for key, value in raw:
            if "\n" in value or "\r" in value:
                raise ValueError(f"the answer {key} holds a line break")
        gated = gating.gated_answers(dict(raw))
        tmp = self.answers_file + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            for key, value in raw:
                if key in gated:
                    stream.write(f"{key}={gated[key]}\n")
        os.replace(tmp, self.answers_file)
        with open(os.path.join(self.state, "consumed-secrets.txt"), "w",
                  encoding="utf-8") as stream:
            for name in sorted(gating.consumed_secrets(dict(raw))):
                stream.write(name + "\n")

    def validate(self, section: str) -> Optional[str]:
        """Run the check of a section of the backend.  None when it
        passed, else the message of the backend."""
        self.write_answers()
        code, out, err = self.backend.section(section, "validate")
        self.log(out + err)
        if code == 0:
            return None
        message = " ".join(err.split()) or f"the {section} check failed"
        return message.replace("installer-backend: ", "")

    # The sections each page checks when it is left.
    PAGE_SECTIONS = {
        "keyboard": ("keyboard",),
        "timezone": ("timezone",),
        "disk": ("disk",),
        "users": ("users",),
        "network": ("network",),
        "summary": ("keyboard", "timezone", "disk", "users", "network", "summary"),
    }

    def leave(self, page: str) -> Optional[str]:
        """The check of a page that is left with Next.  A disk plan was
        checked against the disks of this visit by lib/diskplan.py, and the
        root helper checks it again: the disk list is not read once more."""
        for section in self.PAGE_SECTIONS.get(page, ()):
            if section == "disk" and self.disk_plan:
                continue
            problem = self.validate(section)
            if problem:
                return problem
        return None

    def summary_rows(self) -> List[Tuple[str, str]]:
        a = self.answers
        # The name of the adapter, when the page knows it.
        on = f" on {a.net_if}" if a.net_if else ""
        if a.network_mode == "static":
            net = f"a manual address{on}"
        elif a.network_mode == "offline":
            net = "no network"
        else:
            net = f"an automatic address{on}"
        rows = [
            ("Product", self.product),
            ("Language", a.locale),
            ("Keyboard", a.keymap),
            (TIME_ZONE, a.timezone + (" (the hardware clock keeps local time)"
                                      if a.clock == "local" else "")),
            self.disk_row(),
            ("User", a.user_name + (f" ({a.full_name})" if a.full_name else "")),
            ("Host name", a.hostname or "(the default)"),
            ("SSH key", "yes" if a.ssh_key.strip() else "none"),
            ("Privileges", "passwordless sudo and doas" if a.privilege_passwordless
             else "a password for sudo and doas"),
            ("Network", net),
        ]
        if a.network_mode == "static":
            rows += [("Address", a.ipv4_addr), ("Netmask", a.ipv4_mask),
                     ("Gateway", a.ipv4_gw)]
        names = {i["id"]: i["name"] for i in self.software_catalogue.get("items", [])}
        rows.append((ADDITIONAL_SOFTWARE,
                     ", ".join(names.get(i, i) for i in a.accept_licenses) or
                     "none (no licence accepted)"))
        return rows

    # The groups of the summary page, by the names of summary_rows().
    SUMMARY_GROUPS = (
        ("System", ("Product", "Language", "Keyboard", TIME_ZONE)),
        ("Account", ("User", "Host name", "SSH key", "Privileges")),
        ("Network", ("Network", "Address", "Netmask", "Gateway")),
        ("Software", (ADDITIONAL_SOFTWARE,)),
    )

    def summary_sections(self) -> List[Tuple[str, List[Tuple[str, str]]]]:
        """The rows of the summary in groups (the disks have a list of their
        own); every row of summary_rows() but the disks is in one group."""
        rows = [r for r in self.summary_rows() if r[0] not in ("Disk", "Disks")]
        out = []
        placed = set()
        for title, names in self.SUMMARY_GROUPS:
            items = [r for r in rows if r[0] in names]
            placed.update(r[0] for r in items)
            if items:
                out.append((title, items))
        rest = [r for r in rows if r[0] not in placed]
        if rest:
            out.append(("Other", rest))
        return out

    def disk_row(self) -> Tuple[str, str]:
        """The disks of the plan in one line; the actions follow it."""
        a = self.answers
        plan = self.disk_plan
        if not plan:
            return ("Disk", f"{a.disk} ({a.disk_descr}, {human_size(a.disk_size)})")
        titles = {"erase": "Erase and install", "alongside": "Install alongside", "manual": "Manual"}
        names = list(plan.get("disks") or [])
        if plan.get("mode") == "alongside":
            names = [(plan.get("alongside") or {}).get("disk", "")]
        elif plan.get("mode") == "manual":
            names = sorted({p.get("disk") for p in plan.get("partitions", [])})
        return ("Disks", f"{titles.get(plan.get('mode'), '')}: {', '.join(names)}")

    def erase_warning(self) -> str:
        if self.disk_plan:
            return ""
        a = self.answers
        return (f"Everything on {a.disk} ({a.disk_descr}, {human_size(a.disk_size)}) "
                "will be erased.")

    # ------------------------------------------------------- install

    def submit_dir(self) -> str:
        """The directory the root helper reads: the private directory of the
        secrets, with the answers, the hash and the key in it."""
        self.write_answers()
        target = os.path.join(self.secrets, ANSWERS_NAME)
        shutil.copyfile(self.answers_file, target)
        os.chmod(target, 0o600)
        for name in (PLAN_NAME, "passphrase"):
            try:
                os.unlink(os.path.join(self.secrets, name))
            except OSError:
                pass
        if self.disk_plan is not None:
            plan = dict(self.disk_plan, confirm_foreign=list(self.confirm_foreign))
            write_new_file(os.path.join(self.secrets, PLAN_NAME),
                           (json.dumps(plan, indent=1) + "\n").encode("utf-8"), 0o600)
            if (plan.get("encryption") or {}).get("enabled") and self.passphrase:
                write_new_file(os.path.join(self.secrets, "passphrase"),
                               (self.passphrase + "\n").encode("utf-8"), 0o600)
        return self.secrets

    def install_command(self) -> List[str]:
        return self.backend.helper() + ["--install", self.submit_dir()]

    def reboot_command(self) -> List[str]:
        return self.backend.helper() + ["--reboot"]


class InstallRun:
    """One run of the installation, by the root helper.

    The front end cannot signal the helper (it runs as root): Stop writes
    the line "STOP" to its standard input, and the helper ends the process
    group of the installation.  A stopped run is a failed run, whatever
    the helper says.  Lines are fed by the caller (the GTK main loop or a
    test), so the class needs no thread.
    """

    def __init__(self, wizard: Wizard,
                 on_progress: Callable[[int, str], None],
                 on_log: Callable[[str], None],
                 on_error: Callable[[str], None]):
        self.wizard = wizard
        self.on_progress = on_progress
        self.on_log = on_log
        self.on_error = on_error
        self.proc: Optional[subprocess.Popen] = None
        self.percent = 0
        self.errors: List[str] = []
        self.stopped = False
        self.returncode: Optional[int] = None

    def start(self) -> Optional[str]:
        """Check the disk once more and start the backend.  A message when
        the installation cannot start."""
        problem = self.wizard.leave("summary")
        if problem:
            return problem
        self.wizard.log(f"the disk {self.wizard.answers.disk} was checked before the installation")
        self.proc = subprocess.Popen(
            self.wizard.install_command(), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, stdin=subprocess.PIPE, text=True,
            bufsize=1, env=self.wizard.env, start_new_session=True)
        return None

    def feed(self, line: str) -> None:
        self.wizard.log(line)
        kind, percent, text = parse_line(line)
        if kind == "progress":
            self.percent = percent or 0
            self.on_progress(self.percent, text)
        elif kind == "error":
            self.errors.append(text)
            self.on_error(text)
        self.on_log(line.rstrip("\n"))

    def stop(self) -> None:
        """Ask the helper to end the installation: the line STOP."""
        if self.proc is None or self.proc.poll() is not None:
            return
        self.stopped = True
        self.wizard.log("the installation was stopped by the user")
        if self.proc.stdin is None:
            return
        try:
            self.proc.stdin.write("STOP\n")
            self.proc.stdin.flush()
        except (OSError, ValueError):
            pass

    def kill(self) -> None:
        """The helper did not end: the last resort of a helper that runs as
        this user (a rehearsal).  A helper of root cannot be signalled."""
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except OSError:
            pass

    def finish(self) -> int:
        """Wait for the backend; the secrets are gone afterwards."""
        assert self.proc is not None
        code = self.proc.wait()
        if self.proc.stdin is not None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
        if self.stopped and code == 0:
            code = 1
        self.returncode = code
        self.wizard.delete_secrets()
        self.wizard.log(f"the installation ended with exit code {code}")
        if code == 0:
            self.wizard.installed = True
            self.wizard.install_failed = False
        else:
            self.wizard.install_failed = True
        return code

    def run_blocking(self) -> int:
        """Run to the end without a main loop (tests and the smoke run)."""
        problem = self.start()
        if problem:
            self.on_error(problem)
            return 2
        assert self.proc is not None and self.proc.stdout is not None
        for line in self.proc.stdout:
            self.feed(line)
        return self.finish()


def write_new_file(path: str, data: bytes, mode: int = 0o644) -> None:
    """Write a file that is not there yet, never through a link: the files
    the smoke run writes are opened with O_EXCL and O_NOFOLLOW."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def private_dir_ok(path: str) -> bool:
    """The directory is private: mode 0700 and owned by this user."""
    info = os.lstat(path)
    return stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700 \
        and info.st_uid == os.geteuid()


def find_terminal(names: Iterable[str] = ("xterm", "xfce4-terminal")) -> Optional[str]:
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    return None

# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The parts of the machine the Hardware and drivers window shows.

    python3 -I -B lib/hwprobe.py freebsd|netbsd|openbsd|dragonfly

prints {"devices": [{"class", "name", "driver", "firmware", "status"}],
"unavailable": ["..."]}: the graphics, Ethernet, Wi-Fi, audio, Bluetooth
and input devices, the driver each is attached to (none: "no driver"),
whether the firmware it needs is on the media, and the sources of
information this system did not have ("not available", never an error).

Only reading tools are run, by absolute path, with an empty environment:

  FreeBSD    pciconf -lv, devinfo -v, usbconfig list, ifconfig -l,
             sysctl net.wlan.devices, the names in /boot/firmware,
             /boot/modules and /usr/local/share/firmware
  NetBSD     pcictl pci0 list -N, drvctl -lt, usbdevs -v, ifconfig -l, the
             names in /libdata/firmware
  OpenBSD    pcidump -v (the kernel of the installer refuses it: then the
             kernel messages), usbdevs -v, the names in /etc/firmware
  DragonFly  pciconf -lv, devinfo -v, usbconfig list, ifconfig -l, the names
             in /boot/firmware and /boot/modules

Written against the outputs of those tools on virtual machines
(tests/fixtures/hw-captures); tests replay them.
"""

import json
import os
import re
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

TOOLS = {
    "pciconf": ["/usr/sbin/pciconf"], "devinfo": ["/usr/sbin/devinfo"],
    "usbconfig": ["/usr/sbin/usbconfig"], "ifconfig": ["/sbin/ifconfig"],
    "sysctl": ["/sbin/sysctl"], "pcictl": ["/usr/sbin/pcictl"], "drvctl": ["/sbin/drvctl"],
    "usbdevs": ["/usr/sbin/usbdevs"], "pcidump": ["/usr/sbin/pcidump"], "dmesg": ["/sbin/dmesg"],
    "prtconf": ["/usr/sbin/prtconf"], "scanpci": ["/usr/bin/scanpci"],
}
SYSNAMES = {"freebsd": "freebsd", "netbsd": "netbsd", "openbsd": "openbsd",
            "dragonfly": "dragonfly", "illumos": "sunos"}

# The drivers of Wi-Fi adapters, and the prefix of the firmware files each
# needs ("" when it needs none).
WIFI = {"iwm": "iwm", "iwn": "iwn", "iwx": "iwx", "iwlwifi": "iwlwifi", "ath": "",
        "athn": "athn", "rtwn": "rtwn", "urtwn": "urtwn", "rsu": "rsu", "run": "run",
        "ral": "ral", "rum": "rum", "otus": "otus", "bwfm": "brcmfmac", "bwi": "bwi",
        "bwn": "bwn", "wpi": "wpi", "ipw": "ipw", "iwi": "iwi", "malo": "malo",
        "mtw": "mtw", "qwx": "qwx", "qwz": "qwz", "upgt": "upgt", "zyd": "zd1211",
        "mt7921": "mt7921", "rtw88": "rtw88", "rtw89": "rtw89"}
# Graphics drivers that load firmware (DRM).
GPU_FIRMWARE = {"i915kms": "i915", "i915drm": "i915", "inteldrm": "i915",
                "amdgpu": "amdgpu", "radeonkms": "radeon", "radeon": "radeon",
                "radeondrm": "radeon", "nouveau": "nouveau"}
INPUT = {"hms": "mouse", "hkbd": "keyboard", "ukbd": "keyboard", "ums": "mouse",
         "uts": "touch screen", "atkbd": "keyboard", "psm": "mouse", "pckbd": "keyboard",
         "pms": "mouse", "hmt": "touchpad", "ietp": "touchpad", "ihidev": "touchpad",
         "wsmouse": "", "wskbd": ""}
AUDIO = ("hdac", "hdaa", "pcm", "snd_hda", "hdaudio", "azalia", "auich", "uaudio", "emu")
BLUETOOTH = ("ng_ubt", "ubt", "ubtbcmfw", "iwmbtfw", "ugen_bt")
NO_DRM = "basic display (no DRM driver)"
NOT_NEEDED = "not needed"


class Runner:
    def run(self, key: str, argv: List[str]) -> Tuple[int, str]:
        raise NotImplementedError

    def listdir(self, key: str, path: str) -> Optional[List[str]]:
        """The names under a directory (recursively), or None when it is
        not there."""
        raise NotImplementedError


class Replay(Runner):
    """Captured outputs: <dir>/<key>.out and .rc."""

    def __init__(self, directory: str):
        self.directory = directory
        self.keys: List[str] = []

    def run(self, key, argv):
        self.keys.append(key)
        try:
            with open(os.path.join(self.directory, key + ".out"), encoding="utf-8",
                      errors="replace") as stream:
                out = stream.read()
            with open(os.path.join(self.directory, key + ".rc"), encoding="utf-8") as stream:
                rc = int(stream.read().strip() or "1")
        except (OSError, ValueError):
            return 127, ""
        return rc, out

    def listdir(self, key, path):
        rc, out = self.run(key, ["ls", "-R", path])
        if rc != 0 and not out.strip():
            return None
        return [n for n in out.split() if n and not n.endswith(":")]


class System(Runner):
    ENV = {"PATH": "/sbin:/bin:/usr/sbin:/usr/bin", "LC_ALL": "C"}

    def run(self, key, argv):
        path = next((p for p in TOOLS.get(argv[0], []) if os.access(p, os.X_OK)), None)
        if path is None:
            return 127, ""
        try:
            proc = subprocess.run([path] + argv[1:], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=dict(self.ENV), timeout=30, check=False, cwd="/")
        except (OSError, subprocess.TimeoutExpired):
            return 1, ""
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    def listdir(self, key, path):
        if not os.path.isdir(path):
            return None
        names = []
        for _top, dirs, files in os.walk(path):
            names += dirs + files
            if len(names) > 5000:
                break
        return names


def device(cls, name, driver, firmware=NOT_NEEDED, status=None):
    return {"class": cls, "name": name[:80], "driver": driver or "",
            "firmware": firmware, "status": status or ("working" if driver else "no driver")}


def base(driver: str) -> str:
    """The driver without its unit (em0: em): what re.sub(r"\\d+$", "",
    driver) gives, in one pass from the end."""
    text = driver or ""
    # $ matches before a newline at the end too.
    end = len(text) - 1 if text.endswith("\n") else len(text)
    stem = end
    while stem > 0 and text[stem - 1].isdecimal():
        stem -= 1
    return text[:stem] + text[end:]


def is_unit(word: str) -> bool:
    """Whether a word is a device unit (em0, sd12): what \\w+?\\d+ matches
    of a whole word: two characters or more, a digit last."""
    return len(word) >= 2 and word[-1].isdecimal()


def firmware_state(driver: str, cls: str, files: Optional[List[str]]) -> str:
    """present, missing, not needed, or unknown (no firmware directory)."""
    name = base(driver)
    if cls == "Wi-Fi":
        prefix = WIFI.get(name)
    elif cls == "GPU":
        prefix = GPU_FIRMWARE.get(name)
    else:
        prefix = None
    if not prefix:
        return NOT_NEEDED
    if files is None:
        return "unknown"
    low = [f.lower() for f in files]
    if any(f.startswith(prefix) or f.startswith("if_" + prefix) or prefix in f for f in low):
        return "present"
    return "missing"


# ---------------------------------------------------------- FreeBSD, DragonFly


# The line of a device of `pciconf -lv`: "drv0@pci0:0:2:0:  class=0x030000".
PCICONF_HEAD_RE = re.compile(r"^(\w+)@pci([\d:]+)\s+class=0x([0-9a-f]{6})")


def pciconf_head(line: str) -> Optional[Tuple[str, str, int]]:
    """(driver name, driver with its unit, class code) of the line of a
    device of `pciconf -lv`, or None.  The selector ends with a colon; the
    unit is the digits at the end of the word, the name keeps at least one
    character."""
    m = PCICONF_HEAD_RE.match(line)
    if not m or len(m.group(2)) < 2 or not m.group(2).endswith(":"):
        return None
    word = m.group(1)
    stem = len(word)
    while stem > 1 and word[stem - 1].isdecimal():
        stem -= 1
    return word[:stem], word, int(m.group(3), 16)


def _pci_id(line: str) -> str:
    """vendor:device of the line of a device of `pciconf -lv`, or ""."""
    ids = re.search(r"vendor=0x([0-9a-f]{4}) device=0x([0-9a-f]{4})", line) or \
        re.search(r"chip=0x([0-9a-f]{4})([0-9a-f]{4})", line)
    if not ids:
        return ""
    if "vendor=" in line:
        return f"{ids.group(1)}:{ids.group(2)}"
    # pciconf of DragonFly writes chip=0xDDDDVVVV.
    return f"{ids.group(2)}:{ids.group(1)}"


def parse_pciconf(text: str) -> List[dict]:
    """Devices of `pciconf -lv`: driver (None when "none"), class code,
    vendor and device names."""
    out = []
    current = None
    for line in text.split("\n"):
        head = pciconf_head(line)
        if head:
            stem, drv, code = head
            current = {"driver": None if stem == "none" else drv,
                       "class": code, "vendor": "", "device": "", "id": _pci_id(line)}
            out.append(current)
            continue
        m = re.match(r"^\s+(vendor|device)\s+=\s+'(.*)'$", line)
        if m and current is not None:
            current[m.group(1)] = m.group(2)
    return out


def described(text: str) -> set:
    """The devices of `devinfo -v` with a description: attached to a
    driver (a child without one, like the drmn0 vgapci always has, is a
    place without a driver)."""
    return {line.split()[0] for line in text.split("\n") if line.strip() and "<" in line}


def parse_tree(text: str) -> Dict[str, List[str]]:
    """{device: [its children]} of an indented tree (devinfo -v, drvctl -lt)."""
    children: Dict[str, List[str]] = {}
    stack: List[Tuple[int, str]] = []
    for line in text.split("\n"):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        name = line.split()[0]
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if stack:
            children.setdefault(stack[-1][1], []).append(name)
        stack.append((indent, name))
    return children


def all_names(children: Dict[str, List[str]]) -> List[str]:
    names = list(children)
    for kids in children.values():
        names += kids
    return list(dict.fromkeys(names))


def pci_class(code: int, driver: str) -> Optional[str]:
    if code >> 16 == 0x03:
        return "GPU"
    if code >> 8 == 0x0200:
        return "Wi-Fi" if base(driver) in WIFI else "Ethernet"
    if code >> 8 == 0x0280:
        return "Wi-Fi"
    if code >> 8 in (0x0401, 0x0403):
        return "Audio"
    if code >> 8 == 0x0d11:
        return "Bluetooth"
    return None


def _firmware_files(runner: Runner, dirs: Dict[str, str],
                    unavailable: List[str]) -> Optional[List[str]]:
    """The names in the firmware directories (None: none of them is
    there); a directory that is not there is not available."""
    files: Optional[List[str]] = None
    for path, key in dirs.items():
        names = runner.listdir(key, path)
        if names is None:
            unavailable.append(f"the firmware directory {path}")
        else:
            files = (files or []) + names
    return files


def _tree_devices(tree: Dict[str, List[str]], bluetooth: Tuple[str, ...]) -> List[dict]:
    """The keyboards, mice and tablets, and the Bluetooth adapters, the
    system attached."""
    devices = []
    for name in all_names(tree):
        kind = INPUT.get(base(name))
        if kind:
            devices.append(device("Input", f"{kind} ({name})", name))
        if base(name) in bluetooth:
            devices.append(device("Bluetooth", name, name))
    return devices


def _pci_name(dev: dict, cls: str) -> str:
    """The name of a PCI device, or its vendor, id and class."""
    if dev["device"]:
        return dev["device"]
    pci = f"PCI {dev['id']}" if dev["id"] else ""
    what = "display" if cls == "GPU" else cls
    return " ".join(x for x in (dev["vendor"], pci, what) if x)


def _gpu_status(drv: str, tree: Dict[str, List[str]], attached: Optional[set]) -> Optional[str]:
    """A drm/drmn child is only a place for a DRM driver unless the system
    describes it as attached; a DRM driver itself (i915kms, amdgpu,
    radeonkms) is one."""
    if base(drv) not in ("vgapci", "vga"):
        return None
    drm = [k for k in tree.get(drv, []) if base(k) in GPU_FIRMWARE or
           (base(k) in ("drm", "drmn") and attached is not None and k in attached)]
    return None if drm else NO_DRM


def _fbsd_pci_device(dev: dict, tree: Dict[str, List[str]], attached: Optional[set],
                     files: Optional[List[str]]) -> Optional[dict]:
    """The device of a PCI function of `pciconf -lv`, or None."""
    drv = dev["driver"] or ""
    # A virtio function is a bus: the driver is its child (vtnet0).
    kids = [k for k in tree.get(drv, []) if not k.startswith("virtio")]
    if drv.startswith("virtio_pci") and kids:
        drv = kids[0]
    cls = pci_class(dev["class"], drv)
    if cls is None:
        return None
    status = _gpu_status(drv, tree, attached) if cls == "GPU" else None
    return device(cls, _pci_name(dev, cls), drv, firmware_state(drv, cls, files), status)


def _fbsd_wlans(runner: Runner, devices: List[dict], files: Optional[List[str]]) -> None:
    """The Wi-Fi interfaces of net.wlan.devices no PCI device named."""
    rc, out = runner.run("sysctl_net.wlan.devices", ["sysctl", "net.wlan.devices"])
    if rc != 0:
        return
    for wlan in out.split(":", 1)[-1].split():
        if not any(d["driver"] == wlan for d in devices):
            devices.append(device("Wi-Fi", wlan, wlan, firmware_state(wlan, "Wi-Fi", files)))


def probe_fbsd_like(runner: Runner, os_name: str) -> dict:
    unavailable = []
    rc, out = runner.run("pciconf_-lv", ["pciconf", "-lv"])
    pci = parse_pciconf(out) if rc == 0 else []
    if rc != 0:
        unavailable.append("the PCI devices (pciconf)")
    rc, out = runner.run("devinfo_-v", ["devinfo", "-v"])
    tree = parse_tree(out) if rc == 0 else {}
    # FreeBSD describes every attached device; DragonFly's devinfo has no
    # descriptions, so a child there counts as attached.
    attached = described(out) if rc == 0 and os_name == "freebsd" else None
    if rc != 0:
        unavailable.append("the device tree (devinfo)")
    if os_name == "freebsd":
        dirs = {"/boot/firmware": "ls_-R_boot_firmware", "/boot/modules": "ls_boot_modules",
                "/usr/local/share/firmware": "ls_usr_local_share_firmware"}
    else:
        dirs = {"/boot/firmware /boot/modules": "ls_-R_boot_firmware_boot_modules"}
    files = _firmware_files(runner, dirs, unavailable)
    devices = [d for d in (_fbsd_pci_device(dev, tree, attached, files) for dev in pci) if d]
    # Input: the keyboards, mice and tablets the system attached.
    devices += _tree_devices(tree, BLUETOOTH)
    rc, out = runner.run("usbconfig_list", ["usbconfig", "list"])
    if rc != 0:
        unavailable.append("the USB devices (usbconfig)")
    if os_name == "freebsd":
        _fbsd_wlans(runner, devices, files)
    return {"devices": devices, "unavailable": unavailable}


# ------------------------------------------------------------------ NetBSD


# The selector of a line of `pcictl pci0 list -N` ("000:02:0:"), and the
# driver that may end it (" [vga0]").
PCICTL_HEAD_RE = re.compile(r"^([\d:]+) ")
PCICTL_DRIVER_RE = re.compile(r" \[(\w+)\]")


def pcictl_line(line: str) -> Optional[Tuple[str, str, str]]:
    """(name, kind, driver or "") of a stripped line of `pcictl pci0 list
    -N`: "SEL: NAME (KIND)" with " [DRIVER]" at the end when one is
    attached, or None.  Neither the kind nor the driver holds a ")": the
    kind closes at the last ")" and opens at the last " (" before it (an
    earlier " (" would put more in the kind, the ")" too)."""
    head = PCICTL_HEAD_RE.match(line)
    if not head or len(head.group(1)) < 2 or not head.group(1).endswith(":"):
        return None
    rest = line[head.end():]
    close = rest.rfind(")")
    if close < 0:
        return None
    drv = ""
    if rest[close + 1:]:
        tail = PCICTL_DRIVER_RE.fullmatch(rest, close + 1)
        if not tail:
            return None
        drv = tail.group(1)
    opening = rest.rfind(" (", 0, close)
    if opening < 0 or ")" in rest[opening + 2:close] or "\n" in rest[:opening]:
        return None
    return rest[:opening], rest[opening + 2:close], drv


def _netbsd_class(kind: str, drv: str) -> Optional[str]:
    """The class of a PCI device of pcictl by its kind, or None."""
    if "display" in kind or "vga" in kind:
        return "GPU"
    if "ethernet" in kind:
        return "Ethernet"
    if "wireless" in kind or "802.11" in kind or base(drv) in WIFI:
        return "Wi-Fi"
    if "audio" in kind or "multimedia" in kind:
        return "Audio"
    if "bluetooth" in kind:
        return "Bluetooth"
    return None


def _netbsd_pci_device(line: str, tree: Dict[str, List[str]],
                       files: Optional[List[str]]) -> Optional[dict]:
    """The device of a line of `pcictl pci0 list -N`, or None."""
    found = pcictl_line(line.strip())
    if not found:
        return None
    name, kind, drv = found[0], found[1].lower(), found[2]
    kids = tree.get(drv, [])
    if drv.startswith("virtio") and kids:
        drv = kids[0]
    cls = _netbsd_class(kind, drv)
    if cls is None:
        return None
    status = NO_DRM if cls == "GPU" and base(drv) == "vga" else None
    return device(cls, name, drv, firmware_state(drv, cls, files), status)


def probe_netbsd(runner: Runner) -> dict:
    unavailable = []
    rc, out = runner.run("drvctl_-lt", ["drvctl", "-lt"])
    tree = parse_tree(out) if rc == 0 else {}
    if rc != 0:
        unavailable.append("the device tree (drvctl)")
    files = runner.listdir("ls_-R_libdata_firmware", "/libdata/firmware")
    if files is None:
        unavailable.append("the firmware directory /libdata/firmware")
    rc, out = runner.run("pcictl_pci0_list_-N", ["pcictl", "pci0", "list", "-N"])
    if rc != 0:
        unavailable.append("the PCI devices (pcictl)")
    lines = out.split("\n") if rc == 0 else []
    devices = [d for d in (_netbsd_pci_device(line, tree, files) for line in lines) if d]
    devices += _tree_devices(tree, ("ubt",))
    rc, _out = runner.run("usbdevs_-v", ["usbdevs", "-v"])
    if rc != 0:
        unavailable.append("the USB devices (usbdevs)")
    return {"devices": devices, "unavailable": unavailable}


# ----------------------------------------------------------------- OpenBSD

OPENBSD_CLASS = {"vga": "GPU", "inteldrm": "GPU", "amdgpu": "GPU", "radeondrm": "GPU",
                 "efifb": None, "em": "Ethernet", "re": "Ethernet", "ix": "Ethernet",
                 "igc": "Ethernet", "bge": "Ethernet", "vio": "Ethernet", "alc": "Ethernet",
                 "age": "Ethernet", "msk": "Ethernet", "azalia": "Audio", "auich": "Audio",
                 "uaudio": "Audio", "ubt": "Bluetooth"}


# The kernel messages of OpenBSD: "drv0 at pci0 dev 2 function 0 "Name" rev
# 0x01", "drv0 at bus0", and a PCI device no driver attached.
DMESG_PCI_RE = re.compile(r"^(\w+) at pci\d+ dev \d+ function \d+ ")
DMESG_AT_RE = re.compile(r"^(\w+) at (\w+)")
DMESG_DEV_FUNC_RE = re.compile(r" dev \d+ function \d+ ")
DMESG_NOT_CONFIGURED_RE = re.compile(
    r'^"([^"]*)" rev \S+ at pci\d+ dev \d+ function \d+ not configured')


def _dmesg_label(line: str, pos: int) -> Optional[Tuple[Optional[str], Optional[str]]]:
    """What (?:"([^"]*)"|(.*?) rev) matches at pos: ("quoted name", None),
    (None, "name before rev"), or None."""
    rest = line[pos:]
    if rest.startswith('"'):
        close = rest.find('"', 1)
        if close >= 0:
            return rest[1:close], None
    before = rest.find(" rev")
    if before >= 0 and "\n" not in rest[:before]:
        return None, rest[:before]
    return None


def dmesg_pci_name(line: str) -> Optional[Tuple[str, str]]:
    """(device, name) of the kernel message of a device on a PCI bus, or
    None."""
    m = DMESG_PCI_RE.match(line)
    if not m or not is_unit(m.group(1)):
        return None
    label = _dmesg_label(line, m.end())
    if label is None:
        return None
    return m.group(1), label[0] or (label[1] or "").strip()


def dmesg_attach(line: str) -> Optional[Tuple[str, str, str]]:
    """(device, parent, name) of the kernel message of a device attached
    at a parent, or None.  The parent is the word up to the end of its
    first run of digits (after its first character); the name is there
    for a device at a PCI function only."""
    m = DMESG_AT_RE.match(line)
    if not m or not is_unit(m.group(1)):
        return None
    word = m.group(2)
    digit = next((i for i in range(1, len(word)) if word[i].isdecimal()), None)
    if digit is None:
        return None
    end = digit
    while end < len(word) and word[end].isdecimal():
        end += 1
    name = ""
    func = DMESG_DEV_FUNC_RE.match(line, m.start(2) + end)
    label = _dmesg_label(line, func.end()) if func else None
    if label is not None:
        name = label[0] or (label[1] or "").strip()
    return m.group(1), word[:end], name


def _unconfigured_class(low: str) -> Optional[str]:
    """The class of a PCI device no driver attached, by its name."""
    if "vga" in low or "graphics" in low:
        return "GPU"
    if "wireless" in low or "wi-fi" in low or "wlan" in low:
        return "Wi-Fi"
    if "audio" in low:
        return "Audio"
    if "ethernet" in low:
        return "Ethernet"
    return None


def _openbsd_attached(drv: str, bus: str, name: str, pci_name: Dict[str, str],
                      files: Optional[List[str]]) -> Optional[dict]:
    """The device of a driver attached at a parent, or None."""
    cls = OPENBSD_CLASS.get(base(drv)) or ("Wi-Fi" if base(drv) in WIFI else None)
    if cls is None and base(drv) in INPUT and INPUT[base(drv)]:
        return device("Input", f"{INPUT[base(drv)]} ({drv})", drv)
    if cls is None:
        return None
    # A driver on a virtio function: the name of the function.
    name = name or pci_name.get(bus, "")
    if cls == "GPU" and not name:
        name = "display adapter"
    status = NO_DRM if cls == "GPU" and base(drv) == "vga" else None
    return device(cls, name or drv, drv, firmware_state(drv, cls, files), status)


def _openbsd_dmesg(msgs: str, files: Optional[List[str]]) -> List[dict]:
    """The devices of the kernel messages."""
    parent: Dict[str, str] = {}
    pci_name: Dict[str, str] = {}
    devices = []
    for line in msgs.split("\n"):
        named = dmesg_pci_name(line)
        if named:
            pci_name[named[0]] = named[1]
        attach = dmesg_attach(line)
        if attach:
            drv, bus, name = attach
            parent[drv] = bus
            found = _openbsd_attached(drv, bus, name, pci_name, files)
            if found:
                devices.append(found)
            continue
        m = DMESG_NOT_CONFIGURED_RE.match(line)
        cls = _unconfigured_class(m.group(1).lower()) if m else None
        if cls:
            devices.append(device(cls, m.group(1), ""))
    return devices


def probe_openbsd(runner: Runner) -> dict:
    unavailable = []
    rc, _out = runner.run("pcidump_-v", ["pcidump", "-v"])
    if rc != 0:
        # The kernel of the installer has no pci(4) ioctls: the kernel
        # messages name the devices too.
        unavailable.append("the PCI devices (pcidump); the kernel messages are used")
    rc, msgs = runner.run("dmesg", ["dmesg"])
    if rc != 0:
        unavailable.append("the kernel messages (dmesg)")
        msgs = ""
    files = runner.listdir("ls_etc_firmware", "/etc/firmware")
    if files is None:
        unavailable.append("the firmware directory /etc/firmware")
    devices = _openbsd_dmesg(msgs, files)
    rc, _out = runner.run("usbdevs_-v", ["usbdevs", "-v"])
    if rc != 0:
        unavailable.append("the USB devices (usbdevs)")
    return {"devices": devices, "unavailable": unavailable}


# ----------------------------------------------------------------- illumos

# The drivers of illumos by the class of what they drive.  Its Wi-Fi
# drivers carry their firmware: an attached one needs nothing more.
ILLUMOS_CLASS = {
    "Ethernet": ("vioif", "e1000g", "igb", "ixgbe", "bge", "rge", "rtls", "i40e", "mlxcx",
                 "vmxnet3s", "bnx", "bnxe", "nge", "elxl", "iprb", "afe", "dmfe", "hme",
                 "urtw", "axf", "udmf", "upf", "urf", "cdce"),
    "Wi-Fi": ("iwn", "iwh", "iwk", "iwi", "ipw", "wpi", "ath", "arn", "rwn", "rwd", "rtw",
              "ral", "ural", "uath", "zyd", "rum", "run", "mwl", "pcwl", "pcan", "atu", "urtwn"),
    "GPU": ("vgatext", "i915", "radeon", "nvidia", "gfxp_fb", "efifb", "bochs_drm"),
    "Audio": ("audiohd", "audio1575", "audioens", "audioixp", "audiovia823x", "audioemu10k",
              "audiocmi", "audiosolo", "audiols", "audiop16x", "audiopci", "usb_ac"),
    "Input": ("kb8042", "mouse8042", "usbkbm", "usbms", "hid", "usbwcm"),
}
ILLUMOS_INPUT = {"kb8042": "keyboard", "usbkbm": "keyboard", "mouse8042": "mouse",
                 "usbms": "mouse", "hid": "input device", "usbwcm": "tablet"}
# A class of a device by the words of scanpci, for its name.
SCANPCI_WORDS = {"Ethernet": ("network device", "network controller", "ethernet"), "Wi-Fi": ("wireless", "wi-fi", "802.11"),
                 "GPU": ("vga", "display", "graphics"), "Audio": ("audio",)}
INSTANCE = ", instance #"
DRIVER = " (driver name: "


def _word(ch: str) -> bool:
    """What \\w matches in a str pattern: a letter, a digit, a number or _."""
    return ch.isalnum() or ch == "_"


def _run(text: str, start: int, test) -> int:
    """The end of the run of characters from start that pass test."""
    end = start
    while end < len(text) and test(text[end]):
        end += 1
    return end


def _driver_tail(tail: str) -> Optional[Tuple[Optional[str]]]:
    """( \\(driver name: (\\w+)\\))?\\s*$ on tail: (driver or None,), or None
    when it does not match; the group is tried first."""
    if tail.startswith(DRIVER):
        end = _run(tail, len(DRIVER), _word)
        rest = tail[end + 1:]
        if end > len(DRIVER) and tail[end:end + 1] == ")" and _blank(rest):
            return (tail[len(DRIVER):end],)
    return (None,) if _blank(tail) else None


def _blank(text: str) -> bool:
    """What \\s*$ matches: nothing, or whitespace only."""
    return text == "" or text.isspace()


def _node_tail(tail: str) -> Optional[Tuple[Optional[str], Optional[str]]]:
    """(?:, instance #(\\d+))?(?: \\(driver name: (\\w+)\\))?\\s*$ on tail:
    (instance, driver), each None when absent, or None; the instance is
    tried first."""
    if tail.startswith(INSTANCE):
        end = _run(tail, len(INSTANCE), str.isdecimal)
        if end > len(INSTANCE):
            drv = _driver_tail(tail[end:])
            if drv is not None:
                return tail[len(INSTANCE):end], drv[0]
    drv = _driver_tail(tail)
    return (None, drv[0]) if drv is not None else None


def prtconf_line(line: str) -> Optional[Tuple[str, Optional[str], Optional[str]]]:
    """(node, instance, driver) of a line of `prtconf -D`, or None: what
    ^(\\s*)(\\S.*?)(?:, instance #(\\d+))?(?: \\(driver name: (\\w+)\\))?\\s*$
    matched (no line break in the line), without its backtracking."""
    start = _run(line, 0, str.isspace)
    if start == len(line):
        return None
    for k in range(start + 1, len(line) + 1):
        tail = _node_tail(line[k:])
        if tail is not None:
            return line[start:k], tail[0], tail[1]
    return None


def prtconf_nodes(text: str) -> List[Tuple[str, str, str]]:
    """(node, driver, instance) of `prtconf -D`, for the nodes a driver is
    bound to."""
    out = []
    for line in text.split("\n"):
        found = prtconf_line(line)
        if found and found[2] and line.startswith(" "):
            out.append((found[0].strip(), found[2], found[1] or ""))
    return out


def scanpci_names(text: str) -> List[str]:
    """The description lines of `scanpci`, one per PCI function."""
    out = []
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("pci bus ") and i + 1 < len(lines) and lines[i + 1].startswith(" "):
            out.append(lines[i + 1].strip())
    return out


def _illumos_name(cls: str, node: str, drv: str, pci: List[str]) -> str:
    if cls == "Input":
        return f"{ILLUMOS_INPUT.get(drv, 'input device')} ({drv})"
    named = [n for n in pci if any(w in n.lower() for w in SCANPCI_WORDS.get(cls, ()))]
    # A name only when it can be only that device.
    if len(named) == 1:
        return named[0]
    return f"{node} ({drv})"


def probe_illumos(runner: Runner) -> dict:
    unavailable = []
    rc, out = runner.run("prtconf_-D", ["prtconf", "-D"])
    nodes = prtconf_nodes(out) if rc == 0 else []
    if rc != 0:
        unavailable.append("the device tree (prtconf -D)")
    rc, out = runner.run("scanpci", ["scanpci"])
    pci = scanpci_names(out) if rc == 0 else []
    if rc != 0:
        unavailable.append("the names of the PCI devices (scanpci)")
    devices = []
    for node, drv, _unit in nodes:
        cls = next((c for c, drivers in ILLUMOS_CLASS.items() if drv in drivers), None)
        if cls is None:
            continue
        status = NO_DRM if drv == "vgatext" else None
        devices.append(device(cls, _illumos_name(cls, node, drv, pci), drv,
                              NOT_NEEDED, status))
    return {"devices": devices, "unavailable": unavailable}


def probe(os_name: str, runner: Optional[Runner] = None) -> dict:
    if runner is None:
        if os.uname().sysname.lower() != SYSNAMES.get(os_name):
            return {"devices": [], "unavailable": ["this is not the system named"]}
        runner = System()
    if os_name in ("freebsd", "dragonfly"):
        return probe_fbsd_like(runner, os_name)
    if os_name == "netbsd":
        return probe_netbsd(runner)
    if os_name == "openbsd":
        return probe_openbsd(runner)
    if os_name == "illumos":
        return probe_illumos(runner)
    raise ValueError(f"no hardware probe for {os_name}")


def main(argv: List[str]) -> int:
    args = argv[1:]
    runner = None
    if len(args) == 3 and args[0] == "--replay":
        if os.geteuid() == 0:
            sys.stderr.write("hwprobe: a replay is never run as root\n")
            return 2
        runner = Replay(args[1])
        args = args[2:]
    if len(args) != 1:
        sys.stderr.write("usage: hwprobe.py [--replay DIR] freebsd|netbsd|openbsd|dragonfly|illumos\n")
        return 2
    try:
        report = probe(args[0], runner)
    except ValueError as error:
        sys.stderr.write(f"hwprobe: {error}\n")
        return 2
    print(json.dumps(report, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

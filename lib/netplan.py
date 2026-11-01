# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The network of the installed system: every adapter's IPv4 and IPv6, the
resolvers and the Wi-Fi network.

The answers hold them as lists; this module checks every value (the
backend's network section, the root helper and the adapter all use it)
and builds the options of the install command from them:

  NET_IPV4_LIST  "IF:dhcp" or "IF:ADDR/MASK:GW", separated by ";"   -> -N
  NET_IPV6_LIST  "IF:slaac" or "IF:ADDR6/PREFIXLEN:GW6"             -> -6
  DNS_SERVERS    addresses separated by ","                          -> -D
  UPDATE_AFTER   "yes": update the packages after the installation   -> -U
  WIFI_FILE      a 0600 JSON file {"if", "ssid", "security", "psk"}  -> -W

Usage: netplan.py check FILE  (an answers file: the problems, one a line)
       netplan.py argv FILE   (the options, one a line)
"""

import ipaddress
import json
import os
import re
import stat
import sys
from typing import Dict, List

IF_RE = re.compile(r"[a-z][a-z0-9]{0,14}")
SECURITY = ("open", "wpa2", "wpa3")
MAX_DNS = 8


def _ipv4(text: str) -> bool:
    try:
        ipaddress.IPv4Address(text)
        return text.count(".") == 3
    except ValueError:
        return False


def _ipv6(text: str) -> bool:
    """An IPv6 address; a zone (%em0) only as the name of an adapter: the
    toolkit takes any text after %, and it reaches a command line."""
    if "%" in text:
        _addr, _sep, zone = text.partition("%")
        if not IF_RE.fullmatch(zone):
            return False
    try:
        ipaddress.IPv6Address(text)
        return True
    except ValueError:
        return False


def _entries(text: str, what: str) -> List[tuple]:
    out = []
    for entry in text.split(";"):
        name, sep, rest = entry.partition(":")
        if not sep or not IF_RE.fullmatch(name):
            raise ValueError(f"{what}: '{entry}' does not start with the name of an adapter")
        out.append((name, rest))
    names = [n for n, _r in out]
    if len(names) != len(set(names)):
        raise ValueError(f"{what}: an adapter is given twice")
    return out


def check_ipv4(text: str) -> List[str]:
    """IF:dhcp or IF:ADDR/MASK:GW (GW may be empty: no default route)."""
    try:
        entries = _entries(text, "IPv4")
    except ValueError as error:
        return [str(error)]
    errors = []
    for name, rest in entries:
        if rest == "dhcp":
            continue
        match = re.fullmatch(r"([0-9.]+)/([0-9.]+):([0-9.]*)", rest)
        if not match or not _ipv4(match.group(1)) or not _ipv4(match.group(2)) or \
                (match.group(3) and not _ipv4(match.group(3))):
            errors.append(f"IPv4 of {name}: not dhcp or ADDRESS/NETMASK:GATEWAY")
            continue
        try:
            ipaddress.IPv4Network(f"0.0.0.0/{match.group(2)}")
        except ValueError:
            errors.append(f"IPv4 of {name}: {match.group(2)} is not a netmask")
    return errors


def check_ipv6(text: str) -> List[str]:
    """IF:slaac or IF:ADDR6/PREFIXLEN:GW6 (GW6 may be empty)."""
    try:
        entries = _entries(text, "IPv6")
    except ValueError as error:
        return [str(error)]
    errors = []
    for name, rest in entries:
        if rest == "slaac":
            continue
        # re.ASCII: \d is 0 to 9 only (int() would read another digit).
        match = re.fullmatch(r"([0-9A-Fa-f:]+)/(\d{1,3}):([0-9A-Fa-f:]*)", rest, re.ASCII)
        if not match or not _ipv6(match.group(1)) or not 1 <= int(match.group(2)) <= 128 or \
                (match.group(3) and not _ipv6(match.group(3))):
            errors.append(f"IPv6 of {name}: not slaac or ADDRESS/PREFIX:GATEWAY")
    return errors


def check_dns(text: str) -> List[str]:
    servers = text.split(",")
    if len(servers) > MAX_DNS:
        return [f"at most {MAX_DNS} resolvers"]
    return [f"the resolver '{s}' is not an IPv4 or IPv6 address"
            for s in servers if not (_ipv4(s) or _ipv6(s))]


def check_wifi(path: str) -> List[str]:
    """The Wi-Fi file: 0600, a JSON object of the adapter, the name of the
    network (1 to 32 bytes), the security and its passphrase."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        return [f"the Wi-Fi file cannot be opened: {error.strerror}"]
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            return ["the Wi-Fi file is not a regular file of mode 0600"]
        data = os.read(fd, 4097)
    finally:
        os.close(fd)
    if len(data) > 4096:
        return ["the Wi-Fi file is too large"]
    try:
        net = json.loads(data.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError is a ValueError
        return ["the Wi-Fi file is not JSON"]
    if not isinstance(net, dict) or set(net) != {"if", "ssid", "security", "psk"}:
        return ["the Wi-Fi file is not {if, ssid, security, psk}"]
    return _check_wifi_fields(net)


def _check_wifi_fields(net: dict) -> List[str]:
    """The fields of a Wi-Fi file of the right keys: the adapter, the name
    of the network, the security and its passphrase, in that order."""
    errors = []
    if not isinstance(net["if"], str) or not IF_RE.fullmatch(net["if"]):
        errors.append("the Wi-Fi adapter name is not valid")
    ssid = net["ssid"]
    if not isinstance(ssid, str) or not 1 <= len(ssid.encode("utf-8")) <= 32 or \
            any(ord(c) < 32 for c in ssid):
        errors.append("the name of the Wi-Fi network is not 1 to 32 bytes of text")
    if net["security"] not in SECURITY:
        errors.append("the Wi-Fi security is not open, wpa2 or wpa3")
    psk = net["psk"]
    if not isinstance(psk, str):
        errors.append("the Wi-Fi passphrase is not text")
    elif net["security"] != "open":
        hexkey = len(psk) == 64 and all(c in "0123456789abcdefABCDEF" for c in psk)
        if not hexkey and not (8 <= len(psk) <= 63 and all(32 <= ord(c) < 127 for c in psk)):
            errors.append("the Wi-Fi passphrase is not 8 to 63 printable characters")
    return errors


# The drivers of Wi-Fi adapters on the BSDs.
WIFI_DRIVERS = re.compile(r"(wlan|iwm|iwn|iwx|iwlwifi|ath|athn|rtwn|urtwn|rsu|run|ral|"
                          r"rum|ural|bwi|bwn|wpi|ipw|iwi|malo|mwl|otus|upgt|zyd|mtw|qwx|"
                          r"rtw|bwfm|mt|uath|wi)[0-9]+")


def is_wifi(name: str) -> bool:
    return bool(WIFI_DRIVERS.fullmatch(name or ""))


def parse_scan(text: str) -> List[dict]:
    """The networks a scan found: "ssid|security|signal" a line."""
    out = []
    for line in text.splitlines():
        parts = line.split("|")
        if len(parts) != 3 or not parts[0] or parts[1] not in SECURITY:
            continue
        signal = int(parts[2]) if parts[2].isdigit() else 0
        out.append({"ssid": parts[0][:32], "security": parts[1], "signal": min(signal, 100)})
    return out


def check(answers: Dict[str, str]) -> List[str]:
    errors = []
    if answers.get("NET_IPV4_LIST"):
        errors += check_ipv4(answers["NET_IPV4_LIST"])
    if answers.get("NET_IPV6_LIST"):
        errors += check_ipv6(answers["NET_IPV6_LIST"])
    if answers.get("DNS_SERVERS"):
        errors += check_dns(answers["DNS_SERVERS"])
    if answers.get("UPDATE_AFTER", "no") not in ("yes", "no"):
        errors.append("UPDATE_AFTER is not yes or no")
    if answers.get("WIFI_FILE"):
        errors += check_wifi(answers["WIFI_FILE"])
    return errors


def argv(answers: Dict[str, str]) -> List[str]:
    """The options of the install command; call check first."""
    out = []
    for entry in filter(None, (answers.get("NET_IPV4_LIST") or "").split(";")):
        out += ["-N", entry]
    for entry in filter(None, (answers.get("NET_IPV6_LIST") or "").split(";")):
        out += ["-6", entry]
    for server in filter(None, (answers.get("DNS_SERVERS") or "").split(",")):
        out += ["-D", server]
    if answers.get("WIFI_FILE"):
        out += ["-W", answers["WIFI_FILE"]]
    if answers.get("UPDATE_AFTER") == "yes":
        out.append("-U")
    return out


def _read(path: str) -> Dict[str, str]:
    answers = {}
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.rstrip("\n")
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                answers.setdefault(key, value)
    return answers


def main(args: List[str]) -> int:
    if len(args) != 2 or args[0] not in ("check", "argv"):
        print("usage: netplan.py check|argv ANSWERS", file=sys.stderr)
        return 2
    answers = _read(args[1])
    problems = check(answers)
    if args[0] == "check":
        for problem in problems:
            print(problem)
        return 2 if problems else 0
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 2
    for item in argv(answers):
        print(item)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

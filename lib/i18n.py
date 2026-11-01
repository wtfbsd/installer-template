# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""Languages, their regional variants and the strings of the installer.

LANGUAGES lists every language the installer offers: its own name, its
English name and its variants (locale, country code for the flag, region).
The Welcome page shows one row per language with the flags of its variants
on the right, the way a greeter's language list reads.  Only the variants
the system has (the adapter's list of locales) are offered.

STRINGS holds the text of the installer: English is complete; another
language holds what is translated so far and falls back to English for the
rest.  The language chosen on the Welcome page switches the installer to it
when it has strings.
"""

import os
import re
from typing import Dict, List, Optional

# (language, own name, English name, [(locale, country, region), ...])
LANGUAGES = [
    ("en", "English", "English", [("en_US.UTF-8", "US", "United States"),
                                  ("en_GB.UTF-8", "GB", "United Kingdom"),
                                  ("en_CA.UTF-8", "CA", "Canada"),
                                  ("en_AU.UTF-8", "AU", "Australia")]),
    ("de", "Deutsch", "German", [("de_DE.UTF-8", "DE", "Deutschland"),
                                 ("de_AT.UTF-8", "AT", "Österreich"),
                                 ("de_CH.UTF-8", "CH", "Schweiz")]),
    ("fr", "Français", "French", [("fr_FR.UTF-8", "FR", "France"),
                                  ("fr_CA.UTF-8", "CA", "Canada"),
                                  ("fr_BE.UTF-8", "BE", "Belgique"),
                                  ("fr_CH.UTF-8", "CH", "Suisse")]),
    ("es", "Español", "Spanish", [("es_ES.UTF-8", "ES", "España"),
                                  ("es_MX.UTF-8", "MX", "México"),
                                  ("es_AR.UTF-8", "AR", "Argentina")]),
    ("it", "Italiano", "Italian", [("it_IT.UTF-8", "IT", "Italia"),
                                   ("it_CH.UTF-8", "CH", "Svizzera")]),
    ("pt", "Português", "Portuguese", [("pt_PT.UTF-8", "PT", "Portugal"),
                                       ("pt_BR.UTF-8", "BR", "Brasil")]),
    ("nl", "Nederlands", "Dutch", [("nl_NL.UTF-8", "NL", "Nederland"),
                                   ("nl_BE.UTF-8", "BE", "België")]),
    ("sv", "Svenska", "Swedish", [("sv_SE.UTF-8", "SE", "Sverige")]),
    ("pl", "Polski", "Polish", [("pl_PL.UTF-8", "PL", "Polska")]),
    ("cs", "Čeština", "Czech", [("cs_CZ.UTF-8", "CZ", "Česko")]),
    ("ru", "Русский", "Russian", [("ru_RU.UTF-8", "RU", "Россия")]),
    ("uk", "Українська", "Ukrainian", [("uk_UA.UTF-8", "UA", "Україна")]),
    ("ja", "日本語", "Japanese", [("ja_JP.UTF-8", "JP", "日本")]),
    ("zh", "中文", "Chinese", [("zh_CN.UTF-8", "CN", "中国"), ("zh_TW.UTF-8", "TW", "台灣")]),
]

# The keyboard layout a locale suggests (the console name of FreeBSD,
# which the adapters of the other systems map; see keymap_for).
LAYOUT_OF_COUNTRY = {"US": "us", "GB": "uk", "CA": "us", "AU": "us", "DE": "de", "AT": "de",
                     "CH": "ch", "FR": "fr", "BE": "be", "ES": "es", "MX": "latinamerican",
                     "AR": "latinamerican", "IT": "it", "PT": "pt", "BR": "br", "NL": "us",
                     "SE": "se", "PL": "pl", "CZ": "cz", "RU": "ru", "UA": "ua", "JP": "jp",
                     "CN": "us", "TW": "us"}


def flag_file(country: str, directory: str, scale: int = 1) -> Optional[str]:
    """The image of the flag of a country code in a directory of flags
    (gui/flags: a png file and a twice as large one), or None.  The picker shows an image,
    never a character a colour emoji font may not draw; without a file it
    shows the two letters in a badge."""
    if not re.fullmatch(r"[A-Za-z]{2}", country or ""):
        return None
    for suffix in (("-2x", "") if scale >= 2 else ("",)):
        path = os.path.join(directory, f"{country.lower()}{suffix}.png")
        if os.path.isfile(path):
            return path
    return None


def flag(country: str) -> str:
    """The flag of a country code, as the two regional indicator letters a
    colour emoji font draws as a flag."""
    return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in country.upper() if "A" <= c <= "Z")


def languages_for(available: Optional[List[str]]) -> List[tuple]:
    """The languages and variants the system has: every variant whose
    locale is in the adapter's list (all of them when there is no list)."""
    if not available:
        return list(LANGUAGES)
    have = set(available)
    out = []
    for lang, own, english, variants in LANGUAGES:
        kept = [v for v in variants if v[0] in have]
        if kept:
            out.append((lang, own, english, kept))
    return out


def language_of(locale: str) -> str:
    return locale.split("_", 1)[0]


def keymap_for(locale: str, available: List[str]) -> Optional[str]:
    """The keyboard layout a locale suggests, when the system has it."""
    country = locale.split("_", 1)[1][:2] if "_" in locale else ""
    # The layout of the country, else the layout named after the language.
    for want in (LAYOUT_OF_COUNTRY.get(country), language_of(locale)):
        if not want:
            continue
        for name in available:
            if name == want or name.split(".")[0] == want:
                return name
    return None


# ----------------------------------------------------------------- strings

# The message ids, each defined once; the table of every language below
# is data keyed by them.
PAGE_WELCOME = "page.welcome"
PAGE_KEYBOARD = "page.keyboard"
PAGE_TIMEZONE = "page.timezone"
PAGE_TYPE = "page.type"
PAGE_DISK = "page.disk"
PAGE_USERS = "page.users"
PAGE_NETWORK = "page.network"
PAGE_SOFTWARE = "page.software"
PAGE_SUMMARY = "page.summary"
PAGE_INSTALL = "page.install"
PAGE_FINISH = "page.finish"
WELCOME_READY = "welcome.ready"
WELCOME_TEXT = "welcome.text"
WELCOME_LIVE = "welcome.live"
WELCOME_LANGUAGE = "welcome.language"
ACTION_TRY_LIVE = "action.try-live"
ACTION_NEXT = "action.next"
ACTION_BACK = "action.back"
ACTION_INSTALL_PRODUCT = "action.install-product"
ACTION_STOP = "action.stop"
ACTION_CLOSE = "action.close"
ACTION_INSTALL = "action.install"
ACTION_STAY = "action.stay"
ACTION_REBOOT = "action.reboot"
ACTION_RETRY = "action.retry"
ACTION_QUIT = "action.quit"
ACTION_RESCAN = "action.rescan"
ACTION_OVERRIDE = "action.override"
SLIDE_WELCOME_TITLE = "slide.welcome.title"
SLIDE_WELCOME_TEXT = "slide.welcome.text"
SLIDE_DESKTOP_TITLE = "slide.desktop.title"
SLIDE_DESKTOP_TEXT = "slide.desktop.text"
SLIDE_SOFTWARE_TITLE = "slide.software.title"
SLIDE_SOFTWARE_TEXT = "slide.software.text"
SLIDE_UPDATES_TITLE = "slide.updates.title"
SLIDE_UPDATES_TEXT = "slide.updates.text"
SLIDE_PRIVACY_TITLE = "slide.privacy.title"
SLIDE_PRIVACY_TEXT = "slide.privacy.text"
SLIDE_HELP_TITLE = "slide.help.title"
SLIDE_HELP_TEXT = "slide.help.text"
HARDWARE_TITLE = "hardware.title"
HARDWARE_INTRO = "hardware.intro"
HARDWARE_CLOSE = "hardware.close"
HARDWARE_BUTTON = "hardware.button"
INSTALLING_DETAILS = "installing.details"

STRINGS: Dict[str, Dict[str, str]] = {
    "en": {
        PAGE_WELCOME: "Welcome", PAGE_KEYBOARD: "Keyboard", PAGE_TIMEZONE: "Time zone",
        PAGE_TYPE: "Installation type", PAGE_DISK: "Disk", PAGE_USERS: "Users",
        PAGE_NETWORK: "Network", PAGE_SOFTWARE: "Additional software",
        PAGE_SUMMARY: "Summary", PAGE_INSTALL: "Installing", PAGE_FINISH: "Finished",
        WELCOME_READY: "{product} is ready to be installed.",
        WELCOME_TEXT: "This installer will guide you through installing {product} on this "
                        "machine. It asks for the keyboard, the time zone, the disk, your "
                        "account and the network, shows a summary, and changes nothing "
                        "before you choose Install.",
        WELCOME_LIVE: "Choose Try the live desktop to use the system without installing it. "
                        "The Install {product} icon on the desktop brings the installer back.",
        WELCOME_LANGUAGE: "Language",
        ACTION_TRY_LIVE: "Try the live desktop", ACTION_NEXT: "Next", ACTION_BACK: "Back",
        ACTION_INSTALL_PRODUCT: "Install {product}",
        ACTION_STOP: "Stop the installation", ACTION_CLOSE: "Close", ACTION_INSTALL: "Install",
        ACTION_STAY: "Stay in the live system", ACTION_REBOOT: "Reboot", ACTION_RETRY: "Retry",
        ACTION_QUIT: "Quit", ACTION_RESCAN: "Rescan", ACTION_OVERRIDE: "Override",
        SLIDE_WELCOME_TITLE: "Welcome to {product}",
        SLIDE_WELCOME_TEXT: "While the system is copied, here is what is waiting for you.",
        SLIDE_DESKTOP_TITLE: "A desktop that stays out of your way",
        SLIDE_DESKTOP_TEXT: "Xfce: quick, familiar and easy to change to your liking.",
        SLIDE_SOFTWARE_TITLE: "Thousands of programs",
        SLIDE_SOFTWARE_TEXT: "Install browsers, office suites, games and tools from the package collection.",
        SLIDE_UPDATES_TITLE: "Up to date",
        SLIDE_UPDATES_TEXT: "{product} tells you when updates are ready and installs them when you say so.",
        SLIDE_PRIVACY_TITLE: "Your computer, your data",
        SLIDE_PRIVACY_TEXT: "Nothing is sent anywhere unless you choose to. Encryption keeps your disk private.",
        SLIDE_HELP_TITLE: "Help is near",
        SLIDE_HELP_TEXT: "The handbook and the community answer the questions you have.",
        HARDWARE_TITLE: "Hardware and drivers",
        HARDWARE_INTRO: "What this computer has, the driver each part uses, and whether its firmware is on the media.",
        HARDWARE_CLOSE: "Close",
        HARDWARE_BUTTON: "Hardware and drivers",
        INSTALLING_DETAILS: "Details",
    },
    "de": {
        PAGE_WELCOME: "Willkommen", PAGE_KEYBOARD: "Tastatur", PAGE_TIMEZONE: "Zeitzone",
        PAGE_TYPE: "Installationsart", PAGE_DISK: "Festplatte", PAGE_USERS: "Benutzer",
        PAGE_NETWORK: "Netzwerk", PAGE_SOFTWARE: "Zusätzliche Software",
        PAGE_SUMMARY: "Zusammenfassung", PAGE_INSTALL: "Installation", PAGE_FINISH: "Fertig",
        WELCOME_READY: "{product} kann installiert werden.",
        WELCOME_TEXT: "Dieses Installationsprogramm führt Sie durch die Installation von "
                        "{product} auf diesem Rechner. Es fragt nach Tastatur, Zeitzone, "
                        "Festplatte, Ihrem Konto und dem Netzwerk, zeigt eine Zusammenfassung "
                        "und ändert nichts, bevor Sie „Installieren“ wählen.",
        WELCOME_LIVE: "Wählen Sie „Live-Desktop ausprobieren“, um das System ohne Installation "
                        "zu benutzen. Das Symbol „{product} installieren“ auf dem Desktop öffnet "
                        "das Installationsprogramm wieder.",
        WELCOME_LANGUAGE: "Sprache",
        ACTION_TRY_LIVE: "Live-Desktop ausprobieren", ACTION_NEXT: "Weiter",
        ACTION_BACK: "Zurück", ACTION_INSTALL_PRODUCT: "{product} installieren",
        ACTION_STOP: "Installation abbrechen", ACTION_CLOSE: "Schließen", ACTION_INSTALL: "Installieren",
        ACTION_STAY: "Im Live-System bleiben", ACTION_REBOOT: "Neu starten", ACTION_RETRY: "Wiederholen",
        ACTION_QUIT: "Beenden", ACTION_RESCAN: "Erneut prüfen", ACTION_OVERRIDE: "Trotzdem fortfahren",
        SLIDE_WELCOME_TITLE: "Willkommen bei {product}",
        SLIDE_WELCOME_TEXT: "Während das System kopiert wird, sehen Sie hier, was Sie erwartet.",
        SLIDE_DESKTOP_TITLE: "Ein Desktop, der nicht im Weg steht",
        SLIDE_DESKTOP_TEXT: "Xfce: schnell, vertraut und leicht nach Ihrem Geschmack anzupassen.",
        SLIDE_SOFTWARE_TITLE: "Tausende Programme",
        SLIDE_SOFTWARE_TEXT: "Installieren Sie Browser, Office-Pakete, Spiele und Werkzeuge aus der Paketsammlung.",
        SLIDE_UPDATES_TITLE: "Immer aktuell",
        SLIDE_UPDATES_TEXT: "{product} meldet, wenn Updates bereitstehen, und installiert sie, wenn Sie es sagen.",
        SLIDE_PRIVACY_TITLE: "Ihr Rechner, Ihre Daten",
        SLIDE_PRIVACY_TEXT: "Nichts wird gesendet, solange Sie es nicht wählen. Verschlüsselung schützt Ihre Festplatte.",
        SLIDE_HELP_TITLE: "Hilfe ist nah",
        SLIDE_HELP_TEXT: "Das Handbuch und die Gemeinschaft beantworten Ihre Fragen.",
        HARDWARE_TITLE: "Hardware und Treiber",
        HARDWARE_INTRO: "Was dieser Rechner hat, welchen Treiber jedes Teil benutzt und ob seine Firmware auf dem Medium ist.",
        HARDWARE_CLOSE: "Schließen",
        HARDWARE_BUTTON: "Hardware und Treiber",
        INSTALLING_DETAILS: "Details",
    },
    "fr": {
        PAGE_WELCOME: "Bienvenue", PAGE_KEYBOARD: "Clavier", PAGE_TIMEZONE: "Fuseau horaire",
        PAGE_TYPE: "Type d'installation", PAGE_DISK: "Disque", PAGE_USERS: "Utilisateurs",
        PAGE_NETWORK: "Réseau", PAGE_SOFTWARE: "Logiciels supplémentaires",
        PAGE_SUMMARY: "Résumé", PAGE_INSTALL: "Installation", PAGE_FINISH: "Terminé",
        WELCOME_READY: "{product} est prêt à être installé.",
        WELCOME_LANGUAGE: "Langue",
        ACTION_TRY_LIVE: "Essayer le bureau live", ACTION_NEXT: "Suivant",
        ACTION_BACK: "Précédent", ACTION_INSTALL_PRODUCT: "Installer {product}",
        ACTION_STOP: "Arrêter l'installation", ACTION_CLOSE: "Fermer", ACTION_INSTALL: "Installer",
        ACTION_STAY: "Rester dans le système live", ACTION_REBOOT: "Redémarrer",
        ACTION_RETRY: "Réessayer", ACTION_QUIT: "Quitter", ACTION_RESCAN: "Vérifier à nouveau",
        ACTION_OVERRIDE: "Continuer quand même",
        WELCOME_TEXT: "Cet installateur vous guide pour installer {product} sur cette machine. Il demande "
                        "le clavier, le fuseau horaire, le disque, votre compte et le réseau, affiche un "
                        "résumé et ne modifie rien avant que vous choisissiez Installer.",
        WELCOME_LIVE: "Choisissez Essayer le bureau live pour utiliser le système sans l'installer. "
                        "L'icône Installer {product} du bureau rouvre l'installateur.",
        SLIDE_WELCOME_TITLE: "Bienvenue dans {product}",
        SLIDE_WELCOME_TEXT: "Pendant la copie du système, voici ce qui vous attend.",
        SLIDE_DESKTOP_TITLE: "Un bureau qui ne vous gêne pas",
        SLIDE_DESKTOP_TEXT: "Xfce : rapide, familier et facile à adapter à vos goûts.",
        SLIDE_SOFTWARE_TITLE: "Des milliers de programmes",
        SLIDE_SOFTWARE_TEXT: "Installez navigateurs, suites bureautiques, jeux et outils depuis la collection de paquets.",
        SLIDE_UPDATES_TITLE: "Toujours à jour",
        SLIDE_UPDATES_TEXT: "{product} vous prévient quand des mises à jour sont prêtes et les installe quand vous le décidez.",
        SLIDE_PRIVACY_TITLE: "Votre ordinateur, vos données",
        SLIDE_PRIVACY_TEXT: "Rien n'est envoyé sans votre accord. Le chiffrement protège votre disque.",
        SLIDE_HELP_TITLE: "L'aide est proche",
        SLIDE_HELP_TEXT: "Le manuel et la communauté répondent à vos questions.",
        HARDWARE_TITLE: "Matériel et pilotes",
        HARDWARE_INTRO: "Ce que contient cet ordinateur, le pilote de chaque élément et si son micrologiciel est sur le support.",
        HARDWARE_CLOSE: "Fermer",
        HARDWARE_BUTTON: "Matériel et pilotes",
        INSTALLING_DETAILS: "Détails",
    },
}


def t(key: str, lang: str = "en", **values) -> str:
    """The text of a key in a language, English when it is not translated."""
    text = STRINGS.get(lang, {}).get(key) or STRINGS["en"].get(key) or key
    return text.format(**values) if values else text


def translated(lang: str) -> bool:
    """The installer has strings of its own in this language."""
    return lang in STRINGS


def missing(lang: str) -> List[str]:
    """The English keys a language does not translate yet."""
    return sorted(set(STRINGS["en"]) - set(STRINGS.get(lang, {})))

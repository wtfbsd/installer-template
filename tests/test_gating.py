# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Unit tests for the pure answer gating module.

import contextlib
import io
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))

import gating  # noqa: E402

# The answers the front end of this installer writes.  A gate for a field
# that is not in this list is a gate for a field nothing writes.
ANSWER_KEYS = {
    "KEYMAP",
    "TIMEZONE",
    "DISK",
    "USER_NAME",
    "USER_AUTH",
    "USER_PASSFILE",
    "PRIVILEGE_PASSWORDLESS",
    "NETWORK_MODE",
    "NET_IF",
    "NET_IPV4",
    "IPV4_ADDR",
    "IPV4_MASK",
    "IPV4_GW",
}


class GatedAnswersTest(unittest.TestCase):
    def test_a_gated_off_password_is_dropped(self):
        answers = {
            "USER_AUTH": "none",
            "USER_PASSFILE": "user.pass",
            "USER_NAME": "tester",
        }
        gated = gating.gated_answers(answers)
        self.assertNotIn("USER_PASSFILE", gated)
        self.assertEqual(gated["USER_AUTH"], "none")
        self.assertEqual(gated["USER_NAME"], "tester")

    def test_a_gated_off_password_is_not_a_consumed_secret(self):
        answers = {
            "USER_AUTH": "none",
            "USER_PASSFILE": "user.pass",
        }
        self.assertNotIn("USER_PASSFILE", gating.consumed_secrets(answers))
        self.assertEqual(gating.consumed_secrets(answers), set())

    def test_a_gated_on_password_is_kept(self):
        answers = {
            "USER_AUTH": "password",
            "USER_PASSFILE": "user.pass",
        }
        gated = gating.gated_answers(answers)
        self.assertEqual(gated["USER_PASSFILE"], "user.pass")
        self.assertIn("USER_PASSFILE", gating.consumed_secrets(answers))

    def test_the_answers_are_never_modified(self):
        answers = {
            "USER_AUTH": "none",
            "USER_PASSFILE": "user.pass",
        }
        gating.gated_answers(answers)
        self.assertIn("USER_PASSFILE", answers)

    def test_the_interface_is_kept_in_both_modes(self):
        for mode in ("dhcp", "static"):
            answers = {"NETWORK_MODE": mode, "NET_IF": "em0"}
            self.assertIn("NET_IF", gating.gated_answers(answers))

    def test_the_interface_is_dropped_when_the_system_is_offline(self):
        answers = {"NETWORK_MODE": "offline", "NET_IF": "em0"}
        self.assertNotIn("NET_IF", gating.gated_answers(answers))

    def test_a_manual_address_is_only_used_in_manual_mode(self):
        static = {
            "NETWORK_MODE": "static",
            "NET_IPV4": "static",
            "NET_IF": "em0",
            "IPV4_ADDR": "address",
            "IPV4_MASK": "netmask",
            "IPV4_GW": "gateway",
        }
        self.assertEqual(gating.gated_answers(static), static)

        automatic = dict(static, NETWORK_MODE="dhcp")
        gated = gating.gated_answers(automatic)
        self.assertIn("NET_IF", gated)
        self.assertNotIn("NET_IPV4", gated)
        self.assertNotIn("IPV4_ADDR", gated)
        self.assertNotIn("IPV4_MASK", gated)
        self.assertNotIn("IPV4_GW", gated)

    def test_a_nested_gate_drops_with_its_parent(self):
        answers = {
            "NETWORK_MODE": "dhcp",
            "NET_IPV4": "static",
            "IPV4_ADDR": "address",
            "IPV4_MASK": "netmask",
            "IPV4_GW": "gateway",
        }
        gated = gating.gated_answers(answers)
        self.assertNotIn("IPV4_ADDR", gated)
        self.assertNotIn("IPV4_MASK", gated)
        self.assertNotIn("IPV4_GW", gated)

    def test_the_gate_table_names_a_controller_and_its_values(self):
        for field, (controller, values) in gating.GATES.items():
            self.assertIsInstance(field, str)
            self.assertIsInstance(controller, str)
            self.assertTrue(values)
            self.assertTrue(all(isinstance(value, str) for value in values))


class GateTableTest(unittest.TestCase):
    def test_every_gated_field_is_a_field_of_this_installer(self):
        for field in gating.GATES:
            self.assertIn(field, ANSWER_KEYS)
        for field in gating.SECRET_GATES:
            self.assertIn(field, ANSWER_KEYS)

    def test_every_controller_is_a_field_of_this_installer(self):
        for _field, (controller, _values) in gating.GATES.items():
            self.assertIn(controller, ANSWER_KEYS)

    def test_every_gated_field_has_a_secret_rule_when_it_is_a_password(self):
        for field in ("USER_PASSFILE",):
            self.assertIn(field, gating.GATES)
            self.assertIn(field, gating.SECRET_GATES)

    def test_the_table_is_ordered_so_that_a_nested_gate_drops_with_its_parent(self):
        keys = list(gating.GATES)
        self.assertLess(keys.index("NET_IPV4"), keys.index("IPV4_ADDR"))


class CommandLineTest(unittest.TestCase):
    def test_the_gate_command_reads_standard_input_twice(self):
        text = "USER_AUTH=password\nUSER_PASSFILE=user.pass\n"
        out = io.StringIO()
        err = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(text)):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                first = gating.main(["gate"])
                second = gating.main(["gate"])
        self.assertEqual(first, 0)
        self.assertEqual(second, 0)
        self.assertNotIn("closed file", err.getvalue())
        self.assertIn("USER_PASSFILE=user.pass", out.getvalue())


if __name__ == "__main__":
    unittest.main()

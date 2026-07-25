#!/usr/bin/env python3

"""Deterministic tests for acceptance-only CI helpers."""

from __future__ import annotations

import unittest

from assert_loopback_listener import ListenerAuditError, require_single_listener


class LoopbackListenerAuditTests(unittest.TestCase):
    def test_accepts_exactly_one_expected_loopback_listener(self) -> None:
        require_single_listener(
            "p123\nf9\nn127.0.0.1:17866\n",
            "127.0.0.1",
            17866,
        )

    def test_rejects_no_listener(self) -> None:
        with self.assertRaises(ListenerAuditError):
            require_single_listener("p123\n", "127.0.0.1", 17866)

    def test_rejects_a_wildcard_listener(self) -> None:
        with self.assertRaises(ListenerAuditError):
            require_single_listener(
                "p123\nf9\nn*:17866\n",
                "127.0.0.1",
                17866,
            )

    def test_rejects_an_extra_ipv4_or_ipv6_wildcard_listener(self) -> None:
        for wildcard in ("*:7866", "0.0.0.0:7866", "[::]:7866"):
            with self.subTest(wildcard=wildcard), self.assertRaises(ListenerAuditError):
                require_single_listener(
                    f"p123\nf9\nn127.0.0.1:17866\nf10\nn{wildcard}\n",
                    "127.0.0.1",
                    17866,
                )

    def test_rejects_an_extra_loopback_listener(self) -> None:
        with self.assertRaises(ListenerAuditError):
            require_single_listener(
                "p123\nf9\nn127.0.0.1:17866\nf10\nn127.0.0.1:7866\n",
                "127.0.0.1",
                17866,
            )


if __name__ == "__main__":
    unittest.main()

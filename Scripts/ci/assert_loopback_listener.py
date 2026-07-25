#!/usr/bin/env python3

"""Fail unless lsof reports exactly one expected loopback TCP listener."""

from __future__ import annotations

import argparse
import sys


class ListenerAuditError(ValueError):
    """Raised when the listening-socket contract is not satisfied."""


def parse_lsof_names(output: str) -> list[str]:
    """Parse names from `lsof -Fn` output without accepting human-format rows."""

    return [line[1:] for line in output.splitlines() if line.startswith("n")]


def require_single_listener(output: str, host: str, port: int) -> None:
    expected = f"{host}:{port}"
    listeners = parse_lsof_names(output)
    if listeners != [expected]:
        rendered = ", ".join(repr(listener) for listener in listeners) or "none"
        raise ListenerAuditError(
            "Remote Access must expose exactly "
            f"{expected!r}; observed listening endpoints: {rendered}."
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    arguments = parser.parse_args()
    try:
        require_single_listener(sys.stdin.read(), arguments.host, arguments.port)
    except ListenerAuditError as error:
        print(f"Listener audit failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

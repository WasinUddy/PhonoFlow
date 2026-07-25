#!/usr/bin/env python3

"""Validate the absolute performance gates required by PhonoFlow CI."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


COMMON_GATES = {
    "spectrogram_throughput_x": lambda value: value >= 10.0,
    "non_native_spectrogram_throughput_x": lambda value: value >= 10.0,
    "spectrum_fps": lambda value: 14.0 <= value <= 16.0,
    "capture_to_pixel_p95_ms": lambda value: value < 150.0,
    "hidden_analysis_operations": lambda value: value == 0.0,
    "max_pending_frames": lambda value: value <= 1.0,
    "stft_steady_state_allocations": lambda value: value == 0.0,
}
MAIN_THREAD_STALL_GATE_MS = 16.7


def metrics(document: dict[str, Any]) -> dict[str, float]:
    raw = document.get("metrics")
    if raw is None and all(
        isinstance(value, (int, float)) and not isinstance(value, bool)
        for value in document.values()
    ):
        raw = document
    result: dict[str, float] = {}
    if isinstance(raw, dict):
        iterable = (
            {"name": name, **value} if isinstance(value, dict) else {"name": name, "value": value}
            for name, value in raw.items()
        )
    elif isinstance(raw, list):
        iterable = iter(raw)
    else:
        raise ValueError("benchmark JSON must be a numeric object or contain a 'metrics' object/array")

    for metric in iterable:
        if not isinstance(metric, dict):
            continue
        name = metric.get("name")
        value = metric.get("value")
        if (
            isinstance(name, str)
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(value)
        ):
            result[name] = float(value)
    return result


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate hosted or stable-hardware PhonoFlow performance results. "
            "The default remains the strict stable profile for compatibility."
        )
    )
    parser.add_argument("performance_json", type=Path)
    parser.add_argument(
        "--profile",
        choices=("hosted", "stable"),
        default="stable",
        help=(
            "hosted keeps scheduler-sensitive main-thread stalls diagnostic; "
            "stable enforces the 16.7 ms absolute gate (default: stable)"
        ),
    )
    return parser.parse_args()


def main() -> int:
    options = arguments()

    document = json.loads(options.performance_json.read_text(encoding="utf-8"))
    values = metrics(document)
    gates = dict(COMMON_GATES)
    gates["main_thread_stall_max_ms"] = (
        (lambda value: value >= 0.0)
        if options.profile == "hosted"
        else (lambda value: 0.0 <= value < MAIN_THREAD_STALL_GATE_MS)
    )
    failures: list[str] = []
    measurements = document.get("measurements")
    allowed_measurement_kinds = {
        "counter_delta",
        "duration",
        "duration_samples",
        "high_water_mark",
        "timer_lateness",
    }

    for name, predicate in gates.items():
        if name not in values:
            failures.append(f"missing required metric {name}")
        elif not predicate(values[name]):
            failures.append(f"{name} failed with value {values[name]:g}")

        description = (
            measurements.get(name)
            if isinstance(measurements, dict)
            else None
        )
        if not isinstance(description, dict):
            failures.append(f"missing measurement provenance for {name}")
            continue
        kind = description.get("kind")
        source = description.get("source")
        if kind not in allowed_measurement_kinds:
            failures.append(f"{name} has unsupported measurement kind {kind!r}")
        if not isinstance(source, str) or not source.strip():
            failures.append(f"{name} has no measurement source")

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    if options.profile == "hosted":
        print(
            "diagnostic: "
            f"main_thread_stall_max_ms={values['main_thread_stall_max_ms']:g} "
            "(strictly gated on stable hardware)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

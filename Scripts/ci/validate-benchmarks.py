#!/usr/bin/env python3

"""Validate the absolute performance gates required by PhonoFlow CI."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Any


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


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <performance.json>", file=sys.stderr)
        return 2

    document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    values = metrics(document)
    gates = {
        "spectrogram_throughput_x": lambda value: value >= 10.0,
        "non_native_spectrogram_throughput_x": lambda value: value >= 10.0,
        "spectrum_fps": lambda value: 14.0 <= value <= 16.0,
        "capture_to_pixel_p95_ms": lambda value: value < 150.0,
        "main_thread_stall_max_ms": lambda value: value < 16.7,
        "hidden_analysis_operations": lambda value: value == 0.0,
        "max_pending_frames": lambda value: value <= 1.0,
        "stft_steady_state_allocations": lambda value: value == 0.0,
    }
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

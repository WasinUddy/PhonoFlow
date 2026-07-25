#!/usr/bin/env python3

"""Compare PhonoFlow benchmark JSON without depending on third-party packages."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path
from typing import Any


def parse_metrics(path: Path) -> dict[str, dict[str, Any]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    raw_metrics = document.get("metrics")
    if raw_metrics is None and all(
        isinstance(value, (int, float)) and not isinstance(value, bool)
        for value in document.values()
    ):
        raw_metrics = document
    if isinstance(raw_metrics, dict):
        items = []
        for name, value in raw_metrics.items():
            if isinstance(value, dict):
                items.append({"name": name, **value})
            else:
                items.append({"name": name, "value": value})
    elif isinstance(raw_metrics, list):
        items = raw_metrics
    else:
        raise ValueError(f"{path} must contain a 'metrics' object or array")

    metrics: dict[str, dict[str, Any]] = {}
    for metric in items:
        if not isinstance(metric, dict) or not isinstance(metric.get("name"), str):
            raise ValueError(f"{path} contains a metric without a string name")
        value = metric.get("value")
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ValueError(f"{path}: metric {metric['name']} has a non-finite numeric value")
        metrics[metric["name"]] = metric
    return metrics


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("current", type=Path)
    parser.add_argument("--default-threshold", type=float, default=10.0)
    args = parser.parse_args()

    baseline = parse_metrics(args.baseline)
    current = parse_metrics(args.current)
    failures: list[str] = []
    rows = [
        "| Metric | Baseline | Current | Change | Limit | Result |",
        "|---|---:|---:|---:|---:|:---:|",
    ]

    for name in sorted(baseline.keys() & current.keys()):
        old = float(baseline[name]["value"])
        new = float(current[name]["value"])
        if old == 0:
            delta = 0.0 if new == 0 else math.inf
        else:
            default_lower_is_better = not name.endswith("_throughput_x")
            lower_is_better = bool(
                current[name].get("lowerIsBetter", default_lower_is_better)
            )
            delta = ((new - old) / abs(old)) * 100.0
            if not lower_is_better:
                delta *= -1.0

        limit = float(
            current[name].get(
                "maxRegressionPercent",
                baseline[name].get("maxRegressionPercent", args.default_threshold),
            )
        )
        passed = delta <= limit
        if not passed:
            failures.append(f"{name}: {delta:.2f}% regression exceeds {limit:.2f}%")
        unit = str(current[name].get("unit", ""))
        change = "∞" if math.isinf(delta) else f"{delta:+.2f}%"
        rows.append(
            f"| {name} | {old:g} {unit} | {new:g} {unit} | {change} | "
            f"{limit:.2f}% | {'pass' if passed else 'fail'} |"
        )

    missing = sorted(baseline.keys() - current.keys())
    if missing:
        failures.append("Missing current metrics: " + ", ".join(missing))

    summary = "\n".join(["## Performance regression check", "", *rows, ""])
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write(summary)
    else:
        print(summary)

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

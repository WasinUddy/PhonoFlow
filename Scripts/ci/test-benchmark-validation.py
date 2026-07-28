#!/usr/bin/env python3

"""Regression tests for benchmark gate and provenance validation."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-benchmarks.py")
METRICS = {
    "spectrogram_throughput_x": 20.0,
    "non_native_spectrogram_throughput_x": 20.0,
    "spectrum_fps": 15.0,
    "capture_to_pixel_p95_ms": 20.0,
    "main_thread_stall_max_ms": 2.0,
    "hidden_analysis_operations": 0,
    "max_pending_frames": 1,
    "stft_steady_state_allocations": 0,
}
KINDS = {
    "spectrogram_throughput_x": "duration",
    "non_native_spectrogram_throughput_x": "duration",
    "spectrum_fps": "counter_delta",
    "capture_to_pixel_p95_ms": "duration_samples",
    "main_thread_stall_max_ms": "timer_lateness",
    "hidden_analysis_operations": "counter_delta",
    "max_pending_frames": "high_water_mark",
    "stft_steady_state_allocations": "counter_delta",
}


class BenchmarkValidationTests(unittest.TestCase):
    def validate(
        self,
        document: dict[str, object],
        *,
        profile: str | None = "stable",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "performance.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            command = [str(SCRIPT)]
            if profile is not None:
                command.extend(("--profile", profile))
            command.append(str(path))
            return subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )

    def measured_report(self) -> dict[str, object]:
        return {
            "formatVersion": 2,
            "metrics": dict(METRICS),
            "measurements": {
                name: {"kind": KINDS[name], "source": f"observed {name}"}
                for name in METRICS
            },
        }

    def test_measured_report_passes(self) -> None:
        result = self.validate(self.measured_report())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hosted_profile_reports_main_thread_stall_as_diagnostic(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["main_thread_stall_max_ms"] = 39.5733
        result = self.validate(document, profile="hosted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "main_thread_stall_max_ms=39.5733 (strictly gated on stable hardware)",
            result.stdout,
        )

    def test_stable_profile_enforces_main_thread_stall_gate(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["main_thread_stall_max_ms"] = 16.7
        result = self.validate(document, profile="stable")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("main_thread_stall_max_ms failed", result.stderr)

    def test_default_profile_remains_strict(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["main_thread_stall_max_ms"] = 16.7
        result = self.validate(document, profile=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("main_thread_stall_max_ms failed", result.stderr)

    def test_profiles_reject_negative_main_thread_stall(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["main_thread_stall_max_ms"] = -0.01
        for profile in ("hosted", "stable"):
            with self.subTest(profile=profile):
                result = self.validate(document, profile=profile)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("main_thread_stall_max_ms failed", result.stderr)

    def test_hosted_profile_rejects_non_finite_main_thread_stall(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["main_thread_stall_max_ms"] = float("inf")
        result = self.validate(document, profile="hosted")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required metric main_thread_stall_max_ms", result.stderr)

    def test_legacy_numeric_constants_without_provenance_fail(self) -> None:
        result = self.validate(METRICS)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing measurement provenance", result.stderr)

    def test_empty_measurement_source_fails(self) -> None:
        document = self.measured_report()
        measurements = document["measurements"]
        assert isinstance(measurements, dict)
        measurements["max_pending_frames"] = {
            "kind": "high_water_mark",
            "source": "",
        }
        result = self.validate(document)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no measurement source", result.stderr)

    def test_absolute_gate_still_fails(self) -> None:
        document = self.measured_report()
        metrics = document["metrics"]
        assert isinstance(metrics, dict)
        metrics["spectrogram_throughput_x"] = 9.99
        for profile in ("hosted", "stable"):
            with self.subTest(profile=profile):
                result = self.validate(document, profile=profile)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("spectrogram_throughput_x failed", result.stderr)


if __name__ == "__main__":
    unittest.main()

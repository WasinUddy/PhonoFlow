#!/usr/bin/env python3

"""Regression tests for both native coverage gates."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import ModuleType
from unittest import mock


SCRIPT_DIRECTORY = Path(__file__).parent


def load_script(module_name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, SCRIPT_DIRECTORY / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


APP_GATE = load_script("phonoflow_app_coverage_gate", "coverage-gate.py")
PACKAGE_GATE = load_script(
    "phonoflow_swiftpm_coverage_gate", "swiftpm-coverage-gate.py"
)


def process(
    returncode: int,
    *,
    stdout: str = "",
    stderr: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess((), returncode, stdout, stderr)


def invoke_main(module: ModuleType, *arguments: str) -> tuple[int, str]:
    stderr = io.StringIO()
    with (
        mock.patch.object(sys, "argv", [module.__name__, *arguments]),
        mock.patch.object(module, "append_summary"),
        redirect_stderr(stderr),
    ):
        status = module.main()
    return status, stderr.getvalue()


def lcov_record(path: Path, counts: dict[int, int]) -> str:
    lines = [f"SF:{path}"]
    lines.extend(f"DA:{line},{count}" for line, count in sorted(counts.items()))
    lines.extend(
        [
            f"LF:{len(counts)}",
            f"LH:{sum(count > 0 for count in counts.values())}",
            "end_of_record",
        ]
    )
    return "\n".join(lines) + "\n"


def llvm_coverage_json(
    files: dict[Path, set[int]],
    *,
    line_summaries: dict[Path, tuple[int, int]] | None = None,
) -> str:
    entries = []
    for path, executable_lines in files.items():
        segments = []
        for line in sorted(executable_lines):
            segments.append([line, 1, 1, True, True, False])
            segments.append([line, 2, 0, False, False, False])
        line_count, covered_count = (
            line_summaries[path]
            if line_summaries is not None and path in line_summaries
            else (len(executable_lines), len(executable_lines))
        )
        entries.append(
            {
                "filename": str(path),
                "segments": segments,
                "summary": {
                    "lines": {
                        "count": line_count,
                        "covered": covered_count,
                    }
                },
            }
        )
    return json.dumps({"data": [{"files": entries}]})


class ApplicationCoverageGateTests(unittest.TestCase):
    def test_json_line_counts_are_preferred(self) -> None:
        output = json.dumps(
            {
                "/source.swift": [
                    {"line": line, "isExecutable": False}
                    for line in range(1, 8)
                ]
                + [
                    {"line": 8, "isExecutable": True, "executionCount": 3},
                    {"line": 9, "isExecutable": True, "executionCount": 0},
                ]
            }
        )
        with mock.patch.object(APP_GATE, "run", return_value=process(0, stdout=output)):
            counts = APP_GATE.line_counts(Path("result.xcresult"), "/source.swift")
        self.assertEqual(counts, {8: 3, 9: 0})

    def test_malformed_json_falls_back_to_plain_xccov_output(self) -> None:
        responses = [
            process(0, stdout="{not-json"),
            process(0, stdout="  1: *\n  2: 7\n  3: 0: let value = 1\n"),
        ]
        with mock.patch.object(APP_GATE, "run", side_effect=responses):
            counts = APP_GATE.line_counts(Path("result.xcresult"), "/source.swift")
        self.assertEqual(counts, {2: 7, 3: 0})

    def test_failed_per_line_extraction_fails_closed(self) -> None:
        responses = [
            process(1, stderr="archive query failed"),
            process(1, stderr="text query failed"),
        ]
        with mock.patch.object(APP_GATE, "run", side_effect=responses):
            with self.assertRaisesRegex(
                APP_GATE.CoverageExtractionError,
                "archive query failed.*text query failed",
            ):
                APP_GATE.line_counts(Path("result.xcresult"), "/source.swift")

    def test_structurally_incomplete_per_line_extraction_fails_closed(self) -> None:
        responses = [
            process(
                0,
                stdout=json.dumps(
                    {
                        "/source.swift": [
                            {"line": 1, "isExecutable": False},
                            {"line": 3, "isExecutable": True, "executionCount": 1},
                        ]
                    }
                ),
            ),
            process(0, stdout="1: *\n3: 1\n"),
        ]
        with mock.patch.object(APP_GATE, "run", side_effect=responses):
            with self.assertRaisesRegex(
                APP_GATE.CoverageExtractionError,
                "not unique and contiguous",
            ):
                APP_GATE.line_counts(Path("result.xcresult"), "/source.swift")

    def test_archive_json_fallback_retries_every_requested_file(self) -> None:
        first = "/source/First.swift"
        second = "/source/Second.swift"
        archive_json = json.dumps(
            {
                first: [{"line": 1, "isExecutable": True, "executionCount": 1}],
                second: [{"line": 2, "isExecutable": True, "executionCount": 1}],
            }
        )
        fallback = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
        with (
            mock.patch.object(
                APP_GATE,
                "run",
                return_value=process(0, stdout=archive_json),
            ),
            mock.patch.object(
                APP_GATE,
                "physical_line_coverage",
                side_effect=[fallback, fallback],
            ) as per_file,
        ):
            coverages = APP_GATE.archive_physical_line_coverages(
                Path("result.xcresult"),
                (path for path in (first, second)),
            )
        self.assertEqual(set(coverages), {first, second})
        self.assertEqual(
            [call.args[1] for call in per_file.call_args_list],
            [first, second],
        )

    def test_region_report_count_can_exceed_physical_executable_lines(self) -> None:
        region_executable_lines = 1_904
        physical_executable_lines = 1_569
        physical_source_records = 1_788
        records = [
            {
                "line": line,
                "isExecutable": line <= physical_executable_lines,
                **({"executionCount": 1} if line <= physical_executable_lines else {}),
            }
            for line in range(1, physical_source_records + 1)
        ]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "AppCoordinator.swift"
            source.write_text(
                "\n".join("// source" for _ in range(physical_source_records + 1)),
                encoding="utf-8",
            )
            output = json.dumps({str(source): records})
            with mock.patch.object(
                APP_GATE,
                "run",
                return_value=process(0, stdout=output),
            ):
                counts = APP_GATE.validated_line_counts(
                    Path("result.xcresult"),
                    str(source),
                    {1, physical_source_records},
                )
        self.assertGreater(region_executable_lines, len(counts))
        self.assertEqual(len(counts), physical_executable_lines)

    def test_trailing_nonexecutable_suffix_is_allowed_but_code_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "AudioPipelineWorker.swift"
            source.write_text(
                "\n".join(
                    [
                        "let covered = true",
                        "}",
                        "",
                        "// MARK: - Alias",
                        "typealias NativeMailbox =",
                        "    CoalescedMailbox",
                        "#endif",
                    ]
                ),
                encoding="utf-8",
            )
            physical = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
            APP_GATE.validate_physical_line_coverage(
                physical,
                str(source),
                {6},
            )

            protocol_suffix = root / "PhonoFlow/CoreAudioSystemRuntime.swift"
            protocol_suffix.parent.mkdir()
            protocol_suffix.write_text(
                "\n".join(
                    [
                        "let covered = true",
                        "}",
                        "",
                        "protocol CoreAudioSystemRuntime {",
                        "    func hasProperty(",
                        "        objectID: UInt32",
                        "    ) -> Bool",
                        "}",
                    ]
                ),
                encoding="utf-8",
            )
            APP_GATE.validate_physical_line_coverage(
                physical,
                str(protocol_suffix),
                {7},
            )

            source.write_text(
                "let covered = true\nlet hidden = makeValue()\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                APP_GATE.CoverageExtractionError,
                "not known trailing non-executable syntax",
            ):
                APP_GATE.validate_physical_line_coverage(
                    physical,
                    str(source),
                    set(),
                )

    def test_declaration_only_protocol_can_be_absent_from_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            application = root / "PhonoFlow"
            application.mkdir()
            protocol = application / "AudioUnitHAL.swift"
            protocol.write_text(
                "protocol AudioUnitHALRuntime {\n    func start()\n}\n",
                encoding="utf-8",
            )
            production = application / "Production.swift"
            production.write_text("let covered = true\n", encoding="utf-8")
            result_bundle = root / "Result.xcresult"
            result_bundle.mkdir()
            report = APP_GATE.CoverageFile(str(production), 1, 1)
            physical = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
            with (
                mock.patch.object(APP_GATE, "report_files", return_value=[report]),
                mock.patch.object(
                    APP_GATE,
                    "archive_physical_line_coverages",
                    return_value={str(production): physical},
                ),
                mock.patch.object(
                    APP_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    APP_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(
                    APP_GATE,
                    "changed_swift_lines",
                    return_value={"PhonoFlow/AudioUnitHAL.swift": {2}},
                ),
            ):
                status, stderr = invoke_main(
                    APP_GATE,
                    "--xcresult",
                    str(result_bundle),
                    "--production-minimum",
                    "0",
                )
        self.assertEqual(status, 0, stderr)

    def test_physical_map_validation_is_atomic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            application = root / "PhonoFlow"
            application.mkdir()
            good = application / "Good.swift"
            bad = application / "Bad.swift"
            good.write_text("let covered = true\n", encoding="utf-8")
            bad.write_text(
                "let covered = true\nlet omitted = makeValue()\n",
                encoding="utf-8",
            )
            result_bundle = root / "Result.xcresult"
            result_bundle.mkdir()
            reports = [
                APP_GATE.CoverageFile(str(good), 1, 1),
                APP_GATE.CoverageFile(str(bad), 1, 1),
            ]
            physical = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
            with (
                mock.patch.object(APP_GATE, "report_files", return_value=reports),
                mock.patch.object(
                    APP_GATE,
                    "archive_physical_line_coverages",
                    return_value={str(good): physical, str(bad): physical},
                ),
                mock.patch.object(
                    APP_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    APP_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(
                    APP_GATE,
                    "changed_swift_lines",
                    return_value={"PhonoFlow/Good.swift": {1}},
                ),
            ):
                status, stderr = invoke_main(
                    APP_GATE,
                    "--xcresult",
                    str(result_bundle),
                    "--production-minimum",
                    "0",
                )
        self.assertEqual(status, 1)
        self.assertIn("not known trailing non-executable syntax", stderr)
        self.assertNotIn("has no physical-line coverage", stderr)

    def test_zero_executable_lines_are_labeled_na(self) -> None:
        self.assertEqual(APP_GATE.coverage_label(None), "N/A")
        self.assertNotIn("100", APP_GATE.coverage_label(None))

    def test_invalid_explicit_base_never_falls_back(self) -> None:
        with (
            mock.patch.dict(os.environ, {"COVERAGE_BASE_SHA": "valid-env"}),
            mock.patch.object(APP_GATE, "verify_base_sha", return_value=None) as verify,
        ):
            with self.assertRaisesRegex(
                APP_GATE.InvalidBaseSHAError,
                "does not resolve",
            ):
                APP_GATE.resolve_base_sha("invalid-request")
        verify.assert_called_once_with("invalid-request")

    def test_explicit_all_zero_base_is_invalid(self) -> None:
        with mock.patch.object(APP_GATE, "verify_base_sha") as verify:
            with self.assertRaises(APP_GATE.InvalidBaseSHAError):
                APP_GATE.resolve_base_sha("000000")
        verify.assert_not_called()

    def test_all_zero_environment_base_never_falls_back(self) -> None:
        for module in (APP_GATE, PACKAGE_GATE):
            with self.subTest(module=module.__name__):
                with (
                    mock.patch.dict(
                        os.environ,
                        {"COVERAGE_BASE_SHA": "000000"},
                        clear=True,
                    ),
                    mock.patch.object(module, "verify_base_sha") as verify,
                ):
                    with self.assertRaises(module.InvalidBaseSHAError):
                        module.resolve_base_sha(None)
                verify.assert_not_called()

    def test_unicode_diff_paths_are_not_quoted_away(self) -> None:
        diff = "\n".join(
            [
                "diff --git a/PhonoFlow/音声.swift b/PhonoFlow/音声.swift",
                "--- a/PhonoFlow/音声.swift",
                "+++ b/PhonoFlow/音声.swift",
                "@@ -0,0 +7,2 @@",
            ]
        )
        with mock.patch.object(
            APP_GATE,
            "run",
            return_value=process(0, stdout=diff),
        ) as runner:
            changed = APP_GATE.changed_swift_lines("base")
        self.assertEqual(changed, {"PhonoFlow/音声.swift": {7, 8}})
        self.assertIn("core.quotePath=false", runner.call_args.args)

    def test_valid_explicit_base_is_returned(self) -> None:
        with mock.patch.object(
            APP_GATE,
            "verify_base_sha",
            return_value="resolved-commit",
        ) as verify:
            self.assertEqual(
                APP_GATE.resolve_base_sha("requested"),
                "resolved-commit",
            )
        verify.assert_called_once_with("requested")

    def test_main_fails_when_fallback_base_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "PhonoFlow/Core.swift"
            source.parent.mkdir()
            source.write_text("let covered = true\n", encoding="utf-8")
            result_bundle = root / "Result.xcresult"
            result_bundle.mkdir()
            report = APP_GATE.CoverageFile(str(source), 1, 1)
            physical = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
            with (
                mock.patch.dict(os.environ, {}, clear=True),
                mock.patch.object(APP_GATE, "report_files", return_value=[report]),
                mock.patch.object(
                    APP_GATE,
                    "archive_physical_line_coverages",
                    return_value={str(source): physical},
                ),
                mock.patch.object(
                    APP_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    APP_GATE,
                    "verify_base_sha",
                    return_value=None,
                ) as verify,
            ):
                status, stderr = invoke_main(
                    APP_GATE,
                    "--xcresult",
                    str(result_bundle),
                )
        self.assertEqual(status, 1)
        self.assertIn("no coverage base is available", stderr)
        verify.assert_called_once_with("HEAD^")

    def test_main_fails_when_production_source_is_missing_from_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            application = root / "PhonoFlow"
            application.mkdir()
            present = application / "Present.swift"
            missing = application / "Missing.swift"
            present.write_text("let present = true\n", encoding="utf-8")
            missing.write_text("let missing = true\n", encoding="utf-8")
            result_bundle = root / "Result.xcresult"
            result_bundle.mkdir()
            report = APP_GATE.CoverageFile(str(present), 1, 1)
            physical = APP_GATE.PhysicalLineCoverage({1: 1}, frozenset({1}))
            with (
                mock.patch.object(APP_GATE, "report_files", return_value=[report]),
                mock.patch.object(
                    APP_GATE,
                    "archive_physical_line_coverages",
                    return_value={str(present): physical},
                ),
                mock.patch.object(
                    APP_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    APP_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(APP_GATE, "changed_swift_lines", return_value={}),
            ):
                status, stderr = invoke_main(
                    APP_GATE,
                    "--xcresult",
                    str(result_bundle),
                    "--production-minimum",
                    "0",
                )
        self.assertEqual(status, 1)
        self.assertIn(str(missing), stderr)

    def test_main_aggregate_uses_unique_physical_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "PhonoFlow/Core.swift"
            source.parent.mkdir()
            source.write_text("let covered = true\nlet uncovered = false\n", encoding="utf-8")
            result_bundle = root / "Result.xcresult"
            result_bundle.mkdir()
            region_report = APP_GATE.CoverageFile(str(source), 2, 2)
            physical = APP_GATE.PhysicalLineCoverage(
                {1: 1, 2: 0},
                frozenset({1, 2}),
            )
            with (
                mock.patch.object(
                    APP_GATE,
                    "report_files",
                    return_value=[region_report],
                ),
                mock.patch.object(
                    APP_GATE,
                    "archive_physical_line_coverages",
                    return_value={str(source): physical},
                ),
                mock.patch.object(
                    APP_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    APP_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(APP_GATE, "changed_swift_lines", return_value={}),
            ):
                status, stderr = invoke_main(
                    APP_GATE,
                    "--xcresult",
                    str(result_bundle),
                    "--production-minimum",
                    "75",
                )
        self.assertEqual(status, 1)
        self.assertIn("Non-view production coverage 50.00%", stderr)

    def test_invalid_cli_thresholds_exit_two(self) -> None:
        cases = [
            (
                APP_GATE,
                ["--xcresult", "unused", "--production-minimum"],
            ),
            (
                PACKAGE_GATE,
                [
                    "--coverage-lcov",
                    "unused",
                    "--coverage-json",
                    "unused",
                    "--source-root",
                    "unused",
                    "--minimum",
                ],
            ),
        ]
        for module, prefix in cases:
            for value in ("nan", "inf", "-0.01", "100.01"):
                with self.subTest(module=module.__name__, value=value):
                    with (
                        mock.patch.object(
                            sys,
                            "argv",
                            [module.__name__, *prefix, value],
                        ),
                        redirect_stderr(io.StringIO()),
                    ):
                        with self.assertRaises(SystemExit) as raised:
                            module.main()
                    self.assertEqual(raised.exception.code, 2)

    def test_only_exact_acceptance_scaffolding_is_excluded(self) -> None:
        root = Path("/repo")
        self.assertTrue(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/Remote/RemoteAcceptanceEnvironment.swift",
                root,
            )
        )
        self.assertTrue(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/DebugSupport/FakeCoreAudioHAL.swift",
                root,
            )
        )
        self.assertTrue(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/DebugSupport/FakeCaptureSource.swift",
                root,
            )
        )
        self.assertTrue(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/Platform/SystemAudioUnitHALRuntime.swift",
                root,
            )
        )
        self.assertTrue(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/Platform/SystemCoreAudioRuntime.swift",
                root,
            )
        )
        self.assertFalse(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/CoreAudioHAL.swift",
                root,
            )
        )
        self.assertFalse(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/AudioUnitHAL.swift",
                root,
            )
        )
        self.assertFalse(
            APP_GATE.is_excluded_production_file(
                "/repo/PhonoFlow/CoreAudioSystemRuntime.swift",
                root,
            )
        )


class SwiftPackageCoverageGateTests(unittest.TestCase):
    def test_lcov_is_physical_line_accurate_for_known_exit_segment_regression(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "PhonoFlowCore/Sources/PhonoFlowCore/WAV.swift"
            lcov = "\r\n".join(
                [
                    f"SF:{source}",
                    "DA:10,4",
                    "DA:152,0",
                    "DA:202,0",
                    "DA:320,0",
                    "DA:323,0",
                    "DA:804,0",
                    "LF:6",
                    "LH:1",
                    "end_of_record",
                ]
            )
            coverage = PACKAGE_GATE.parse_lcov(lcov, root)
        counts = coverage.files[str(source.resolve())]
        self.assertEqual(counts[10], 4)
        for line in (152, 202, 320, 323, 804):
            self.assertEqual(counts[line], 0)

    def test_lcov_accepts_llvm_line_summary_totals_with_physical_da_records(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "PhonoFlowCore/Sources/PhonoFlowCore/Core.swift"
            lcov = "\n".join(
                [
                    f"SF:{source}",
                    "DA:10,4",
                    "DA:20,0",
                    "LF:4",
                    "LH:3",
                    "end_of_record",
                ]
            )
            coverage = PACKAGE_GATE.parse_lcov(lcov, root)

        self.assertEqual(
            coverage.files[str(source.resolve())],
            {10: 4, 20: 0},
        )
        self.assertEqual(
            coverage.line_summaries[str(source.resolve())],
            PACKAGE_GATE.CoverageMeasurement(covered=3, executable=4),
        )

    def test_invalid_lcov_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with self.assertRaisesRegex(
                PACKAGE_GATE.CoverageDataError,
                "DA data before an SF",
            ):
                PACKAGE_GATE.parse_lcov("DA:1,1\n", root)
            with self.assertRaisesRegex(
                PACKAGE_GATE.CoverageDataError,
                "non-numeric",
            ):
                PACKAGE_GATE.parse_lcov(
                    "SF:source.swift\nDA:one,1\nend_of_record\n",
                    root,
                )
            with self.assertRaisesRegex(
                PACKAGE_GATE.CoverageDataError,
                "ends before end_of_record",
            ):
                PACKAGE_GATE.parse_lcov("SF:source.swift\nDA:1,1\n", root)
            with self.assertRaisesRegex(
                PACKAGE_GATE.CoverageDataError,
                "starts an SF record before end_of_record",
            ):
                PACKAGE_GATE.parse_lcov(
                    "SF:first.swift\nSF:second.swift\nend_of_record\n",
                    root,
                )
            with self.assertRaisesRegex(
                PACKAGE_GATE.CoverageDataError,
                "declares LH:2 greater than LF:1",
            ):
                PACKAGE_GATE.parse_lcov(
                    "\n".join(
                        [
                            "SF:source.swift",
                            "DA:1,1",
                            "LF:1",
                            "LH:2",
                            "end_of_record",
                        ]
                    ),
                    root,
                )

    def test_production_scope_uses_exact_benchmark_exclusion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources"
            core = str((sources / "PhonoFlowCore/Core.swift").resolve())
            benchmark = str((sources / "PhonoFlowBenchmarks/main.swift").resolve())
            similarly_named = str(
                (sources / "PhonoFlowBenchmarksExtra/main.swift").resolve()
            )
            files = {
                core: {1: 1},
                benchmark: {1: 0},
                similarly_named: {1: 1},
            }
            selected = PACKAGE_GATE.production_files(
                files,
                sources,
                {benchmark},
            )
        self.assertEqual(set(selected), {core, similarly_named})

    def test_missing_production_source_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources"
            present = sources / "PhonoFlowCore/Present.swift"
            missing = sources / "PhonoFlowCore/Missing.swift"
            present.parent.mkdir(parents=True)
            present.write_text("public let present = true\n", encoding="utf-8")
            missing.write_text("public let missing = true\n", encoding="utf-8")
            absent = sorted(
                PACKAGE_GATE.production_source_inventory(
                    sources,
                    set(),
                )
                - {str(present.resolve())}
            )
        self.assertEqual(absent, [str(missing.resolve())])

    def test_changed_measurement_intersects_only_lcov_executable_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources"
            relative = "PhonoFlowCore/Sources/PhonoFlowCore/Core.swift"
            source = str((root / relative).resolve())
            result = PACKAGE_GATE.changed_measurement(
                files={source: {10: 2, 11: 0}},
                changed={relative: {10, 11, 12}},
                repository_root=root,
                source_root=sources,
                exclusions=set(),
            )
        self.assertEqual(result.measurement, PACKAGE_GATE.CoverageMeasurement(1, 2))
        self.assertEqual(result.uncovered_lines, ((relative, 11),))
        self.assertEqual(result.failures, ())

    def test_comment_only_change_is_na(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources"
            relative = "PhonoFlowCore/Sources/PhonoFlowCore/Core.swift"
            source = str((root / relative).resolve())
            result = PACKAGE_GATE.changed_measurement(
                files={source: {10: 1}},
                changed={relative: {12}},
                repository_root=root,
                source_root=sources,
                exclusions=set(),
            )
        self.assertEqual(result.measurement, PACKAGE_GATE.CoverageMeasurement(0, 0))
        self.assertIsNone(result.measurement.ratio)
        self.assertEqual(PACKAGE_GATE.coverage_label(result.measurement.ratio), "N/A")

    def test_missing_changed_source_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources"
            relative = "PhonoFlowCore/Sources/PhonoFlowCore/New.swift"
            result = PACKAGE_GATE.changed_measurement(
                files={},
                changed={relative: {1}},
                repository_root=root,
                source_root=sources,
                exclusions=set(),
            )
        self.assertIn("absent from coverage", result.failures[0])

    def test_aggregate_uses_unique_physical_lines(self) -> None:
        measurement = PACKAGE_GATE.aggregate_measurement(
            {
                "/Core.swift": {1: 3, 2: 0},
                "/WAV.swift": {1: 1},
            }
        )
        self.assertEqual(measurement, PACKAGE_GATE.CoverageMeasurement(2, 3))
        self.assertAlmostEqual(measurement.ratio, 66.666666, places=5)

    def test_package_invalid_explicit_base_never_falls_back(self) -> None:
        with (
            mock.patch.dict(os.environ, {"COVERAGE_BASE_SHA": "valid-env"}),
            mock.patch.object(PACKAGE_GATE, "verify_base_sha", return_value=None) as verify,
        ):
            with self.assertRaises(PACKAGE_GATE.InvalidBaseSHAError):
                PACKAGE_GATE.resolve_base_sha("invalid-request")
        verify.assert_called_once_with("invalid-request")

    def test_package_main_fails_when_fallback_base_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sources = root / "PhonoFlowCore/Sources/PhonoFlowCore"
            sources.mkdir(parents=True)
            source = sources / "Core.swift"
            source.write_text("let covered = true\n", encoding="utf-8")
            coverage_path = root / "coverage.lcov"
            coverage_path.write_text(lcov_record(source, {1: 1}), encoding="utf-8")
            coverage_json_path = root / "coverage.json"
            coverage_json_path.write_text(
                llvm_coverage_json({source: {1}}),
                encoding="utf-8",
            )
            with (
                mock.patch.dict(os.environ, {}, clear=True),
                mock.patch.object(
                    PACKAGE_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "verify_base_sha",
                    return_value=None,
                ) as verify,
            ):
                status, stderr = invoke_main(
                    PACKAGE_GATE,
                    "--coverage-lcov",
                    str(coverage_path),
                    "--coverage-json",
                    str(coverage_json_path),
                    "--source-root",
                    str(root / "PhonoFlowCore/Sources"),
                )
        self.assertEqual(status, 1)
        self.assertIn("no coverage base is available", stderr)
        verify.assert_called_once_with("HEAD^")

    def test_package_main_accepts_llvm_line_summary_totals(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source_root = root / "PhonoFlowCore/Sources"
            source = source_root / "PhonoFlowCore/Core.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                "let covered = true\nlet uncovered = false\n",
                encoding="utf-8",
            )
            coverage_path = root / "coverage.lcov"
            coverage_path.write_text(
                "\n".join(
                    [
                        f"SF:{source}",
                        "DA:1,4",
                        "DA:2,0",
                        "LF:4",
                        "LH:3",
                        "end_of_record",
                    ]
                ),
                encoding="utf-8",
            )
            coverage_json_path = root / "coverage.json"
            coverage_json_path.write_text(
                llvm_coverage_json(
                    {source: {1, 2}},
                    line_summaries={source: (4, 3)},
                ),
                encoding="utf-8",
            )
            with (
                mock.patch.object(
                    PACKAGE_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "changed_swift_lines",
                    return_value={},
                ),
            ):
                status, stderr = invoke_main(
                    PACKAGE_GATE,
                    "--coverage-lcov",
                    str(coverage_path),
                    "--coverage-json",
                    str(coverage_json_path),
                    "--source-root",
                    str(source_root),
                    "--minimum",
                    "0",
                )

        self.assertEqual(status, 0)
        self.assertEqual(stderr, "")

    def test_package_main_rejects_lcov_summary_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source_root = root / "PhonoFlowCore/Sources"
            source = source_root / "PhonoFlowCore/Core.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                "let first = true\nlet second = true\n",
                encoding="utf-8",
            )
            coverage_path = root / "coverage.lcov"
            coverage_path.write_text(
                "\n".join(
                    [
                        f"SF:{source}",
                        "DA:1,1",
                        "DA:2,1",
                        "LF:2",
                        "LH:1",
                        "end_of_record",
                    ]
                ),
                encoding="utf-8",
            )
            coverage_json_path = root / "coverage.json"
            coverage_json_path.write_text(
                llvm_coverage_json({source: {1, 2}}),
                encoding="utf-8",
            )
            with (
                mock.patch.object(
                    PACKAGE_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "changed_swift_lines",
                    return_value={},
                ),
            ):
                status, stderr = invoke_main(
                    PACKAGE_GATE,
                    "--coverage-lcov",
                    str(coverage_path),
                    "--coverage-json",
                    str(coverage_json_path),
                    "--source-root",
                    str(source_root),
                    "--minimum",
                    "0",
                )

        self.assertEqual(status, 1)
        self.assertIn("LLVM JSON reports 2 covered of 2 lines", stderr)

    def test_package_main_rejects_incomplete_or_stale_lcov(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source_root = root / "PhonoFlowCore/Sources"
            core = source_root / "PhonoFlowCore/Core.swift"
            other = source_root / "PhonoFlowCore/Other.swift"
            core.parent.mkdir(parents=True)
            core.write_text("let first = true\nlet second = false\n", encoding="utf-8")
            other.write_text("let other = true\n", encoding="utf-8")
            valid_other = lcov_record(other, {1: 1})
            coverage_json_path = root / "coverage.json"
            coverage_json_path.write_text(
                llvm_coverage_json({core: {1, 2}, other: {1}}),
                encoding="utf-8",
            )
            cases = {
                "truncated DA set": (
                    "\n".join(
                        [
                            f"SF:{core}",
                            "DA:1,1",
                            "LF:2",
                            "LH:2",
                            "end_of_record",
                            "",
                        ]
                    )
                    + valid_other,
                    "incomplete or stale",
                ),
                "empty production record": (
                    "\n".join(
                        [
                            f"SF:{core}",
                            "LF:0",
                            "LH:0",
                            "end_of_record",
                            "",
                        ]
                    )
                    + valid_other,
                    "incomplete or stale",
                ),
                "out of range DA": (
                    lcov_record(core, {999: 1}) + valid_other,
                    "out-of-range physical lines",
                ),
            }
            for name, (lcov, expected_error) in cases.items():
                with self.subTest(name=name):
                    coverage_path = root / f"{name}.lcov"
                    coverage_path.write_text(lcov, encoding="utf-8")
                    with (
                        mock.patch.object(
                            PACKAGE_GATE,
                            "run",
                            return_value=process(0, stdout=str(root)),
                        ),
                        mock.patch.object(
                            PACKAGE_GATE,
                            "resolve_base_sha",
                            return_value="base",
                        ),
                        mock.patch.object(
                            PACKAGE_GATE,
                            "changed_swift_lines",
                            return_value={},
                        ),
                    ):
                        status, stderr = invoke_main(
                            PACKAGE_GATE,
                            "--coverage-lcov",
                            str(coverage_path),
                            "--coverage-json",
                            str(coverage_json_path),
                            "--source-root",
                            str(source_root),
                            "--minimum",
                            "0",
                        )
                    self.assertEqual(status, 1)
                    self.assertIn(expected_error, stderr)

    def test_package_main_rejects_empty_production_record_as_changed_na(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source_root = root / "PhonoFlowCore/Sources"
            core = source_root / "PhonoFlowCore/Core.swift"
            other = source_root / "PhonoFlowCore/Other.swift"
            core.parent.mkdir(parents=True)
            core.write_text("let silentlyMissing = true\n", encoding="utf-8")
            other.write_text("let measured = true\n", encoding="utf-8")

            coverage_path = root / "coverage.lcov"
            coverage_path.write_text(
                "\n".join(
                    [
                        f"SF:{core}",
                        "LF:0",
                        "LH:0",
                        "end_of_record",
                        "",
                    ]
                )
                + lcov_record(other, {1: 1}),
                encoding="utf-8",
            )
            coverage_json_path = root / "coverage.json"
            coverage_json_path.write_text(
                llvm_coverage_json({core: set(), other: {1}}),
                encoding="utf-8",
            )
            relative_core = str(core.relative_to(root))
            with (
                mock.patch.object(
                    PACKAGE_GATE,
                    "run",
                    return_value=process(0, stdout=str(root)),
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "resolve_base_sha",
                    return_value="base",
                ),
                mock.patch.object(
                    PACKAGE_GATE,
                    "changed_swift_lines",
                    return_value={relative_core: {1}},
                ),
            ):
                status, stderr = invoke_main(
                    PACKAGE_GATE,
                    "--coverage-lcov",
                    str(coverage_path),
                    "--coverage-json",
                    str(coverage_json_path),
                    "--source-root",
                    str(source_root),
                    "--minimum",
                    "0",
                )

        self.assertEqual(status, 1)
        self.assertIn(
            "no executable physical lines for production source",
            stderr,
        )


if __name__ == "__main__":
    unittest.main()

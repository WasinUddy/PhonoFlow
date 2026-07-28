#!/usr/bin/env python3

"""Enforce aggregate and changed-line coverage from an Xcode result bundle."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


EXCLUDED_PRODUCTION_FILES = frozenset(
    {
        # Exact debug/acceptance fixtures and raw C-API forwarding shims.
        "PhonoFlow/DebugSupport/FakeCoreAudioHAL.swift",
        "PhonoFlow/DebugSupport/FakeCaptureSource.swift",
        "PhonoFlow/Remote/RemoteAcceptanceEnvironment.swift",
        "PhonoFlow/Platform/SystemAudioUnitHALRuntime.swift",
        "PhonoFlow/Platform/SystemCoreAudioRuntime.swift",
    }
)

KNOWN_NON_EXECUTABLE_PRODUCTION_FILES = frozenset(
    {
        # Declaration-only injectable protocol; it produces no xccov record.
        "PhonoFlow/AudioUnitHAL.swift",
    }
)

KNOWN_NON_EXECUTABLE_TRAILING_DECLARATION_FILES = frozenset(
    {
        # Executable listener registration precedes a protocol-only suffix.
        "PhonoFlow/CoreAudioSystemRuntime.swift",
    }
)


@dataclass(frozen=True)
class CoverageFile:
    path: str
    covered_lines: int
    executable_lines: int


@dataclass(frozen=True)
class PhysicalLineCoverage:
    execution_counts: dict[int, int]
    recorded_lines: frozenset[int]


class CoverageExtractionError(RuntimeError):
    """Raised when xccov cannot provide per-line data for a covered file."""


class InvalidBaseSHAError(ValueError):
    """Raised when a caller explicitly configures an unusable diff base."""


def run(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def report_files(result_bundle: Path) -> list[CoverageFile]:
    result = run(
        "xcrun",
        "xccov",
        "view",
        "--report",
        "--json",
        str(result_bundle),
    )
    document = json.loads(result.stdout)
    files: dict[str, CoverageFile] = {}

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            path = node.get("path")
            covered = node.get("coveredLines")
            executable = node.get("executableLines")
            if (
                isinstance(path, str)
                and isinstance(covered, int)
                and isinstance(executable, int)
                and path.endswith(".swift")
            ):
                files[path] = CoverageFile(path, covered, executable)
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(document)
    return list(files.values())


def is_test_file(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return bool(
        re.search(r"/(?:Tests|UITests|IntegrationTests|AcceptanceTests)/", normalized)
        or "/.build/" in normalized
        or "/DerivedData/" in normalized
    )


def is_view_file(path: str) -> bool:
    normalized = path.replace("\\", "/")
    name = Path(normalized).name
    return bool(
        re.search(r"/(?:UI|Views?)/", normalized)
        or name.endswith("View.swift")
        or name in {"PhonoFlowApp.swift", "UIComponents.swift"}
    )


def is_below(path: str, root: Path) -> bool:
    normalized = path.replace("\\", "/")
    source_root = str(root.resolve()).replace("\\", "/").rstrip("/") + "/"
    return normalized.startswith(source_root)


def repository_relative_path(path: str, repository_root: Path) -> str | None:
    normalized = path.replace("\\", "/")
    root = str(repository_root.resolve()).replace("\\", "/").rstrip("/")
    if normalized.startswith(root + "/"):
        return normalized[len(root) + 1 :]
    if not normalized.startswith("/"):
        return normalized.removeprefix("./")
    return None


def is_excluded_production_file(path: str, repository_root: Path) -> bool:
    relative = repository_relative_path(path, repository_root)
    return relative in EXCLUDED_PRODUCTION_FILES


def coverage(files: Iterable[CoverageFile]) -> tuple[int, int, float]:
    selected = list(files)
    covered = sum(item.covered_lines for item in selected)
    executable = sum(item.executable_lines for item in selected)
    ratio = (covered / executable * 100.0) if executable else 0.0
    return covered, executable, ratio


def percentage(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number from 0 through 100") from error
    if not math.isfinite(parsed) or not 0.0 <= parsed <= 100.0:
        raise argparse.ArgumentTypeError("must be a finite number from 0 through 100")
    return parsed


def production_source_paths(
    application_root: Path,
    repository_root: Path,
) -> set[str]:
    return {
        str(path.resolve()).replace("\\", "/")
        for path in application_root.rglob("*.swift")
        if not is_test_file(str(path))
        and not is_view_file(str(path))
        and not is_excluded_production_file(str(path), repository_root)
    }


def known_non_executable_source_paths(repository_root: Path) -> set[str]:
    return {
        str((repository_root / relative_path).resolve()).replace("\\", "/")
        for relative_path in KNOWN_NON_EXECUTABLE_PRODUCTION_FILES
    }


def has_exact_repository_suffix(path: str, candidates: Iterable[str]) -> bool:
    normalized = path.replace("\\", "/")
    return any(
        normalized == candidate or normalized.endswith("/" + candidate)
        for candidate in candidates
    )


def declaration_only_protocol_source(
    source_lines: list[str],
    first_line: int = 1,
) -> tuple[bool, list[int]]:
    invalid: list[int] = []
    saw_protocol = False
    closed_protocol = False
    in_block_comment = False

    for line_number in range(first_line, len(source_lines) + 1):
        stripped = source_lines[line_number - 1].strip()
        if in_block_comment:
            if "*/" in stripped:
                stripped = stripped.split("*/", 1)[1].strip()
                in_block_comment = False
            else:
                continue
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            if "*/" in stripped[2:]:
                stripped = stripped.split("*/", 1)[1].strip()
                if not stripped:
                    continue
            else:
                in_block_comment = True
                continue
        stripped = stripped.split("//", 1)[0].strip()
        if not stripped:
            continue

        if not saw_protocol:
            if re.fullmatch(r"import\s+[A-Za-z_][A-Za-z0-9_]*", stripped):
                continue
            if stripped == "}":
                continue
            if re.fullmatch(
                r"(?:nonisolated\s+)?(?:public\s+|internal\s+|private\s+)?"
                r"protocol\s+[A-Za-z_][A-Za-z0-9_]*[^{}]*\{",
                stripped,
            ):
                saw_protocol = True
                continue
            invalid.append(line_number)
            continue

        if closed_protocol:
            invalid.append(line_number)
            continue
        if stripped == "}":
            closed_protocol = True
            continue
        if re.match(
            r"^(?:func|var|associatedtype|typealias|init|subscript)\b",
            stripped,
        ):
            continue
        if re.fullmatch(
            r"(?:_|[A-Za-z_][A-Za-z0-9_]*)"
            r"(?:\s+(?:_|[A-Za-z_][A-Za-z0-9_]*))?\s*:\s*[^=]+,?",
            stripped,
        ):
            continue
        if re.fullmatch(
            r"\)\s*(?:async\s+)?(?:throws\s+)?(?:->\s*.+)?",
            stripped,
        ):
            continue
        if re.fullmatch(r"@\w+(?:\([^)]*\))?", stripped):
            continue
        invalid.append(line_number)

    if in_block_comment or not saw_protocol or not closed_protocol:
        invalid.append(len(source_lines))
    return not invalid, sorted(set(invalid))


def non_executable_trailing_suffix(
    source_lines: list[str],
    first_omitted_line: int,
) -> tuple[bool, list[int]]:
    invalid: list[int] = []
    in_typealias = False
    in_block_comment = False

    for line_number in range(first_omitted_line, len(source_lines) + 1):
        raw = source_lines[line_number - 1]
        stripped = raw.strip()

        if in_block_comment:
            if "*/" in stripped:
                stripped = stripped.split("*/", 1)[1].strip()
                in_block_comment = False
            else:
                continue
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            if "*/" in stripped[2:]:
                stripped = stripped.split("*/", 1)[1].strip()
                if not stripped:
                    continue
            else:
                in_block_comment = True
                continue

        stripped = stripped.split("//", 1)[0].strip()
        if not stripped:
            continue
        if re.fullmatch(r"[}\])]+[;,]?", stripped):
            in_typealias = False
            continue
        if re.fullmatch(r"#endif(?:\s+.*)?", stripped):
            in_typealias = False
            continue
        if re.fullmatch(
            r"typealias\s+[A-Za-z_][A-Za-z0-9_]*"
            r"(?:\s*<[^=]+>)?\s*=\s*"
            r"[A-Za-z0-9_@.<>,?!&()[\]:\s=-]*",
            stripped,
        ):
            in_typealias = stripped.endswith("=")
            continue
        if in_typealias and re.fullmatch(
            r"[A-Za-z0-9_@.<>,?!&()[\]:\s=-]+",
            stripped,
        ):
            continue

        invalid.append(line_number)

    if in_block_comment:
        invalid.append(len(source_lines))
    return not invalid, sorted(set(invalid))


def changed_swift_lines(base_sha: str) -> dict[str, set[int]]:
    diff = run(
        "git",
        "-c",
        "core.quotePath=false",
        "diff",
        "--find-renames",
        "--diff-filter=ACMR",
        "--unified=0",
        "--no-color",
        f"{base_sha}...HEAD",
        "--",
        "*.swift",
    ).stdout
    changed: dict[str, set[int]] = {}
    current_path: str | None = None

    for line in diff.splitlines():
        if line.startswith("+++ "):
            candidate = line[4:]
            current_path = candidate[2:] if candidate.startswith("b/") else None
            if current_path is not None:
                changed.setdefault(current_path, set())
            continue
        if not line.startswith("@@") or current_path is None:
            continue
        match = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        changed[current_path].update(range(start, start + count))

    return changed


def matching_json_records(node: Any, report_path: str) -> list[Any]:
    if not isinstance(node, dict) or not node:
        raise CoverageExtractionError("JSON output is not a source-file mapping")

    requested = str(Path(report_path).resolve()).replace("\\", "/")
    matches = [
        records
        for path, records in node.items()
        if isinstance(path, str)
        and str(Path(path).resolve()).replace("\\", "/") == requested
    ]
    if len(matches) != 1:
        raise CoverageExtractionError(
            "JSON output does not contain exactly one matching source-file record"
        )
    records = matches[0]
    if not isinstance(records, list) or not records:
        raise CoverageExtractionError("JSON source-file record has no physical lines")
    return records


def json_physical_line_coverage(
    node: Any,
    report_path: str,
) -> PhysicalLineCoverage:
    records = matching_json_records(node, report_path)
    counts: dict[int, int] = {}
    recorded: set[int] = set()

    for expected_line, record in enumerate(records, start=1):
        if not isinstance(record, dict):
            raise CoverageExtractionError(
                f"JSON physical-line record {expected_line} is not an object"
            )
        line = record.get("line")
        executable = record.get("isExecutable")
        if type(line) is not int or line != expected_line:
            raise CoverageExtractionError(
                "JSON physical-line records are not unique and contiguous from line 1"
            )
        if type(executable) is not bool:
            raise CoverageExtractionError(
                f"JSON physical-line record {line} has no Boolean isExecutable field"
            )
        recorded.add(line)
        if not executable:
            continue
        count = record.get("executionCount")
        if type(count) is not int or count < 0:
            raise CoverageExtractionError(
                f"JSON executable physical line {line} has no valid executionCount"
            )
        counts[line] = count

    return PhysicalLineCoverage(counts, frozenset(recorded))


def text_physical_line_coverage(document: str) -> PhysicalLineCoverage:
    counts: dict[int, int] = {}
    recorded: set[int] = set()
    for raw_line in document.splitlines():
        if not raw_line.strip():
            continue
        match = re.match(
            r"^\s*(\d+)\s*:\s*(\d+|\*)(?:\s*:\s*.*)?\s*$",
            raw_line,
        )
        if match is None:
            raise CoverageExtractionError("text output has an invalid physical-line record")
        line = int(match.group(1))
        if line != len(recorded) + 1:
            raise CoverageExtractionError(
                "text physical-line records are not unique and contiguous from line 1"
            )
        recorded.add(line)
        if match.group(2) != "*":
            counts[line] = int(match.group(2))

    if not recorded:
        raise CoverageExtractionError("text output has no physical-line records")
    return PhysicalLineCoverage(counts, frozenset(recorded))


def physical_line_coverage(
    result_bundle: Path,
    report_path: str,
) -> PhysicalLineCoverage:
    diagnostics: list[str] = []
    result = run(
        "xcrun",
        "xccov",
        "view",
        "--archive",
        "--file",
        report_path,
        "--json",
        str(result_bundle),
        check=False,
    )
    if result.returncode == 0:
        try:
            return json_physical_line_coverage(
                json.loads(result.stdout),
                report_path,
            )
        except json.JSONDecodeError as error:
            diagnostics.append(f"invalid JSON output ({error})")
        except CoverageExtractionError as error:
            diagnostics.append(str(error))
    else:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        diagnostics.append(f"JSON query failed ({detail})")

    plain = run(
        "xcrun",
        "xccov",
        "view",
        "--archive",
        "--file",
        report_path,
        str(result_bundle),
        check=False,
    )
    if plain.returncode == 0:
        try:
            return text_physical_line_coverage(plain.stdout)
        except CoverageExtractionError as error:
            diagnostics.append(str(error))
    else:
        detail = plain.stderr.strip() or f"exit status {plain.returncode}"
        diagnostics.append(f"text query failed ({detail})")

    raise CoverageExtractionError(
        f"xccov could not extract per-line coverage for {report_path}: "
        + "; ".join(diagnostics)
    )


def archive_physical_line_coverages(
    result_bundle: Path,
    report_paths: Iterable[str],
) -> dict[str, PhysicalLineCoverage]:
    requested_paths = tuple(report_paths)
    archive = run(
        "xcrun",
        "xccov",
        "view",
        "--archive",
        "--json",
        str(result_bundle),
        check=False,
    )
    if archive.returncode == 0:
        try:
            document = json.loads(archive.stdout)
            return {
                report_path: json_physical_line_coverage(document, report_path)
                for report_path in requested_paths
            }
        except (json.JSONDecodeError, CoverageExtractionError):
            # A per-file query has a defensible text representation, so use it
            # as the compatibility fallback for older xccov JSON shapes.
            pass

    return {
        report_path: physical_line_coverage(result_bundle, report_path)
        for report_path in requested_paths
    }


def line_counts(result_bundle: Path, report_path: str) -> dict[int, int]:
    return physical_line_coverage(result_bundle, report_path).execution_counts


def validate_physical_line_coverage(
    coverage: PhysicalLineCoverage,
    report_path: str,
    required_lines: set[int],
) -> None:
    source_lines = Path(report_path).read_text(encoding="utf-8").splitlines()
    source_line_count = len(source_lines)
    recorded_line_count = len(coverage.recorded_lines)
    if recorded_line_count > source_line_count:
        raise CoverageExtractionError(
            f"xccov returned {recorded_line_count} physical-line records for a "
            f"{source_line_count}-line source file: {report_path}"
        )
    suffix_is_non_executable, invalid_suffix_lines = non_executable_trailing_suffix(
        source_lines,
        recorded_line_count + 1,
    )
    if (
        not suffix_is_non_executable
        and has_exact_repository_suffix(
            report_path,
            KNOWN_NON_EXECUTABLE_TRAILING_DECLARATION_FILES,
        )
    ):
        suffix_is_non_executable, invalid_suffix_lines = (
            declaration_only_protocol_source(
                source_lines,
                recorded_line_count + 1,
            )
        )
    if not suffix_is_non_executable:
        raise CoverageExtractionError(
            f"xccov omitted source lines that are not known trailing "
            f"non-executable syntax for {report_path}: "
            + ", ".join(map(str, invalid_suffix_lines))
        )
    missing_required = required_lines - coverage.recorded_lines
    if missing_required and any(
        line <= recorded_line_count or line > source_line_count
        for line in missing_required
    ):
        raise CoverageExtractionError(
            "xccov omitted changed physical lines for "
            f"{report_path}: {', '.join(map(str, sorted(missing_required)))}"
        )


def validated_line_counts(
    result_bundle: Path,
    report_path: str,
    required_lines: set[int],
) -> dict[int, int]:
    coverage = physical_line_coverage(result_bundle, report_path)
    validate_physical_line_coverage(coverage, report_path, required_lines)
    return coverage.execution_counts


def verify_base_sha(candidate: str) -> str | None:
    result = run(
        "git",
        "rev-parse",
        "--verify",
        "--end-of-options",
        f"{candidate}^{{commit}}",
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def resolve_base_sha(requested: str | None) -> str | None:
    if requested is not None:
        if not requested or set(requested) == {"0"}:
            raise InvalidBaseSHAError(f"invalid explicitly requested base SHA: {requested!r}")
        if resolved := verify_base_sha(requested):
            return resolved
        raise InvalidBaseSHAError(
            f"explicitly requested base SHA does not resolve to a commit: {requested}"
        )

    configured = os.environ.get("COVERAGE_BASE_SHA")
    if configured:
        if set(configured) == {"0"}:
            raise InvalidBaseSHAError(
                "COVERAGE_BASE_SHA is an all-zero sentinel, not a valid commit"
            )
        if resolved := verify_base_sha(configured):
            return resolved
        raise InvalidBaseSHAError(
            "COVERAGE_BASE_SHA does not resolve to a commit: " + configured
        )

    if resolved := verify_base_sha("HEAD^"):
        return resolved
    raise InvalidBaseSHAError(
        "no coverage base is available; provide --base-sha or COVERAGE_BASE_SHA"
    )


def coverage_label(ratio: float | None) -> str:
    return f"{ratio:.2f}%" if ratio is not None else "N/A"


def append_summary(lines: list[str]) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    body = "\n".join(lines) + "\n"
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write(body)
    else:
        print(body)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True, type=Path)
    parser.add_argument("--base-sha")
    parser.add_argument("--production-minimum", type=percentage, default=80.0)
    parser.add_argument("--changed-minimum", type=percentage, default=90.0)
    args = parser.parse_args()

    if not args.xcresult.exists():
        print(f"error: result bundle does not exist: {args.xcresult}", file=sys.stderr)
        return 1

    try:
        all_files = report_files(args.xcresult)
        repository_root = Path(
            run("git", "rev-parse", "--show-toplevel").stdout.strip()
        ).resolve()
    except (json.JSONDecodeError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: unable to load Xcode coverage report: {error}", file=sys.stderr)
        return 1
    application_root = repository_root / "PhonoFlow"
    production = [
        item
        for item in all_files
        if is_below(item.path, application_root)
        and not is_test_file(item.path)
        and not is_view_file(item.path)
        and not is_excluded_production_file(item.path, repository_root)
    ]
    failures: list[str] = []
    reported_production_paths = {
        str(Path(item.path).resolve()).replace("\\", "/") for item in production
    }
    all_production_sources = production_source_paths(
        application_root,
        repository_root,
    )
    known_non_executable_sources = known_non_executable_source_paths(
        repository_root
    )
    missing_production_sources = (
        all_production_sources
        - known_non_executable_sources
        - reported_production_paths
    )
    if missing_production_sources:
        failures.append(
            "Production sources are absent from Xcode coverage: "
            + ", ".join(sorted(missing_production_sources))
        )
    validated_known_non_executable_sources: set[str] = set()
    for source_path in sorted(
        all_production_sources
        & known_non_executable_sources
        - reported_production_paths
    ):
        try:
            is_declaration_only, invalid_lines = declaration_only_protocol_source(
                Path(source_path).read_text(encoding="utf-8").splitlines()
            )
        except OSError as error:
            failures.append(
                f"Unable to validate known non-executable source {source_path}: {error}"
            )
            continue
        if not is_declaration_only:
            failures.append(
                f"Known non-executable source now contains unsupported syntax "
                f"{source_path}: "
                + ", ".join(map(str, invalid_lines))
            )
            continue
        relative_path = repository_relative_path(source_path, repository_root)
        if relative_path is not None:
            validated_known_non_executable_sources.add(relative_path)

    physical_by_report_path: dict[str, PhysicalLineCoverage] = {}
    physical_archive_valid = False
    try:
        extracted = archive_physical_line_coverages(
            args.xcresult,
            (item.path for item in production),
        )
        expected_report_paths = {
            item.path.replace("\\", "/") for item in production
        }
        returned_report_paths = {
            report_path.replace("\\", "/") for report_path in extracted
        }
        missing_physical_reports = expected_report_paths - returned_report_paths
        if missing_physical_reports:
            raise CoverageExtractionError(
                "Xcode archive omitted physical coverage for production sources: "
                + ", ".join(sorted(missing_physical_reports))
            )
        candidate_physical: dict[str, PhysicalLineCoverage] = {}
        validation_failures: list[str] = []
        for report_path, physical in extracted.items():
            try:
                validate_physical_line_coverage(physical, report_path, set())
            except (CoverageExtractionError, OSError) as error:
                validation_failures.append(str(error))
                continue
            candidate_physical[report_path.replace("\\", "/")] = physical
        if validation_failures:
            failures.extend(validation_failures)
        else:
            physical_by_report_path = candidate_physical
            physical_archive_valid = True
    except (CoverageExtractionError, OSError) as error:
        failures.append(str(error))

    prod_executable = sum(
        len(item.execution_counts) for item in physical_by_report_path.values()
    )
    prod_covered = sum(
        1
        for item in physical_by_report_path.values()
        for count in item.execution_counts.values()
        if count > 0
    )
    prod_ratio = (
        prod_covered / prod_executable * 100.0 if prod_executable else 0.0
    )

    if not production:
        failures.append("No non-view production coverage was found in the result bundle")
    elif physical_archive_valid and prod_executable == 0:
        failures.append("No executable physical production lines were found")
    elif physical_archive_valid and prod_ratio < args.production_minimum:
        failures.append(
            f"Non-view production coverage {prod_ratio:.2f}% is below "
            f"{args.production_minimum:.2f}%"
        )

    try:
        base_sha = resolve_base_sha(args.base_sha)
    except InvalidBaseSHAError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    changed_covered = 0
    changed_executable = 0
    changed_ratio: float | None = None
    if base_sha:
        try:
            changed = changed_swift_lines(base_sha)
        except subprocess.CalledProcessError as error:
            detail = error.stderr.strip() if error.stderr else str(error)
            failures.append(f"Unable to diff changed Swift lines: {detail}")
            changed = {}
        report_by_suffix = {item.path.replace("\\", "/"): item for item in production}
        missing_changed_files: list[str] = []
        extraction_failures: list[str] = []
        for relative_path, changed_lines in changed.items():
            if not relative_path.startswith("PhonoFlow/"):
                continue
            if is_test_file("/" + relative_path) or is_view_file("/" + relative_path):
                continue
            if relative_path in EXCLUDED_PRODUCTION_FILES:
                continue
            report_path = next(
                (
                    path
                    for path in report_by_suffix
                    if path == relative_path or path.endswith("/" + relative_path)
                ),
                None,
            )
            if report_path is None:
                if relative_path in validated_known_non_executable_sources:
                    continue
                missing_changed_files.append(relative_path)
                continue
            if not physical_archive_valid:
                continue
            try:
                physical = physical_by_report_path[report_path]
                validate_physical_line_coverage(
                    physical,
                    report_path,
                    changed_lines,
                )
                counts = physical.execution_counts
            except KeyError:
                extraction_failures.append(
                    f"Xcode archive has no physical-line coverage for {relative_path}"
                )
                continue
            except CoverageExtractionError as error:
                extraction_failures.append(str(error))
                continue
            executable_changed = changed_lines & counts.keys()
            changed_executable += len(executable_changed)
            changed_covered += sum(1 for line in executable_changed if counts[line] > 0)

        if missing_changed_files:
            failures.append(
                "Changed production files are absent from coverage: "
                + ", ".join(sorted(missing_changed_files))
            )

        failures.extend(extraction_failures)

        if changed_executable:
            changed_ratio = changed_covered / changed_executable * 100.0
            if changed_ratio < args.changed_minimum:
                failures.append(
                    f"Changed-line coverage {changed_ratio:.2f}% is below "
                    f"{args.changed_minimum:.2f}%"
                )

    append_summary(
        [
            "## Swift coverage",
            "",
            "| Scope | Covered / executable lines | Coverage | Required |",
            "|---|---:|---:|---:|",
            (
                f"| Non-view production | {prod_covered} / {prod_executable} | "
                f"{prod_ratio:.2f}% | {args.production_minimum:.2f}% |"
            ),
            (
                f"| Changed executable lines | {changed_covered} / {changed_executable} | "
                f"{coverage_label(changed_ratio)} | {args.changed_minimum:.2f}% |"
            ),
            "",
            f"Diff base: `{base_sha or 'unavailable'}`",
            "",
        ]
    )

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

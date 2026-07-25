#!/usr/bin/env python3

"""Enforce aggregate and changed physical-line coverage for Swift packages."""

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
from typing import Any


class CoverageDataError(ValueError):
    """Raised when LLVM LCOV data cannot support a fail-closed gate."""


class InvalidBaseSHAError(ValueError):
    """Raised when a configured diff base cannot be resolved."""


@dataclass(frozen=True)
class CoverageMeasurement:
    covered: int
    executable: int

    @property
    def ratio(self) -> float | None:
        if self.executable == 0:
            return None
        return self.covered / self.executable * 100.0


@dataclass(frozen=True)
class ChangedCoverage:
    measurement: CoverageMeasurement
    failures: tuple[str, ...]
    uncovered_lines: tuple[tuple[str, int], ...]


def run(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


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


def percentage(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number from 0 through 100") from error
    if not math.isfinite(parsed) or not 0.0 <= parsed <= 100.0:
        raise argparse.ArgumentTypeError("must be a finite number from 0 through 100")
    return parsed


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


def normalized_path(path: str | Path, base: Path | None = None) -> str:
    candidate = Path(path)
    if not candidate.is_absolute() and base is not None:
        candidate = base / candidate
    return str(candidate.resolve()).replace("\\", "/")


def parse_lcov(document: str, repository_root: Path) -> dict[str, dict[int, int]]:
    """Parse LCOV into one maximum execution count per physical source line."""

    files: dict[str, dict[int, int]] = {}
    current_path: str | None = None
    current_counts: dict[int, int] = {}
    declared_lines_found: int | None = None
    declared_lines_hit: int | None = None
    saw_record = False

    for line_number, raw_line in enumerate(document.splitlines(), start=1):
        line = raw_line.rstrip("\r")
        if line.startswith("SF:"):
            if current_path is not None:
                raise CoverageDataError(
                    f"LCOV line {line_number} starts an SF record before "
                    "end_of_record"
                )
            source = line[3:]
            if not source:
                raise CoverageDataError(f"LCOV line {line_number} has an empty SF record")
            current_path = normalized_path(source, repository_root)
            current_counts = {}
            declared_lines_found = None
            declared_lines_hit = None
            saw_record = True
            continue
        if line.startswith("DA:"):
            if current_path is None:
                raise CoverageDataError(
                    f"LCOV line {line_number} has DA data before an SF record"
                )
            fields = line[3:].split(",")
            if len(fields) < 2:
                raise CoverageDataError(f"LCOV line {line_number} has an invalid DA record")
            try:
                source_line = int(fields[0])
                execution_count = int(fields[1])
            except ValueError as error:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a non-numeric DA record"
                ) from error
            if source_line < 1 or execution_count < 0:
                raise CoverageDataError(
                    f"LCOV line {line_number} has an invalid line/count"
                )
            if source_line in current_counts:
                raise CoverageDataError(
                    f"LCOV line {line_number} duplicates physical line {source_line}"
                )
            current_counts[source_line] = execution_count
            continue
        if line.startswith("LF:"):
            if current_path is None or declared_lines_found is not None:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a misplaced or duplicate LF record"
                )
            try:
                declared_lines_found = int(line[3:])
            except ValueError as error:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a non-numeric LF record"
                ) from error
            if declared_lines_found < 0:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a negative LF record"
                )
            continue
        if line.startswith("LH:"):
            if current_path is None or declared_lines_hit is not None:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a misplaced or duplicate LH record"
                )
            try:
                declared_lines_hit = int(line[3:])
            except ValueError as error:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a non-numeric LH record"
                ) from error
            if declared_lines_hit < 0:
                raise CoverageDataError(
                    f"LCOV line {line_number} has a negative LH record"
                )
            continue
        if line == "end_of_record":
            if current_path is None:
                raise CoverageDataError(
                    f"LCOV line {line_number} ends a record before an SF record"
                )
            if declared_lines_found is None or declared_lines_hit is None:
                raise CoverageDataError(
                    f"LCOV record for {current_path} has no LF/LH completeness totals"
                )
            physical_lines_found = len(current_counts)
            physical_lines_hit = sum(count > 0 for count in current_counts.values())
            if declared_lines_found != physical_lines_found:
                raise CoverageDataError(
                    f"LCOV record for {current_path} declares LF:"
                    f"{declared_lines_found} but contains "
                    f"{physical_lines_found} unique DA records"
                )
            if declared_lines_hit != physical_lines_hit:
                raise CoverageDataError(
                    f"LCOV record for {current_path} declares LH:"
                    f"{declared_lines_hit}, LF:{declared_lines_found}, and "
                    f"{physical_lines_hit} covered DA records"
                )
            merged = files.setdefault(current_path, {})
            for source_line, execution_count in current_counts.items():
                merged[source_line] = max(
                    merged.get(source_line, 0),
                    execution_count,
                )
            current_path = None
            current_counts = {}
            declared_lines_found = None
            declared_lines_hit = None

    if current_path is not None:
        raise CoverageDataError("LCOV input ends before end_of_record")
    if not saw_record:
        raise CoverageDataError("LCOV input contains no source-file records")
    return files


def executable_lines_from_segments(entry: dict[str, Any]) -> set[int]:
    raw_segments = entry.get("segments")
    if not isinstance(raw_segments, list):
        raise CoverageDataError(
            f"LLVM JSON has no segment data for {entry.get('filename', '<unknown>')}"
        )

    segments: list[tuple[int, int, bool, bool]] = []
    for raw in raw_segments:
        if (
            not isinstance(raw, list)
            or len(raw) < 6
            or type(raw[0]) is not int
            or type(raw[1]) is not int
            or type(raw[2]) is not int
            or not isinstance(raw[3], (bool, int))
            or not isinstance(raw[5], (bool, int))
        ):
            raise CoverageDataError(
                f"LLVM JSON contains an invalid segment for "
                f"{entry.get('filename', '<unknown>')}"
            )
        line = int(raw[0])
        column = int(raw[1])
        if line < 1 or column < 1 or int(raw[2]) < 0:
            raise CoverageDataError(
                f"LLVM JSON contains an invalid segment position/count for "
                f"{entry.get('filename', '<unknown>')}"
            )
        segments.append((line, column, bool(raw[3]), bool(raw[5])))

    segments.sort(key=lambda segment: (segment[0], segment[1]))
    executable: set[int] = set()
    for index, segment in enumerate(segments[:-1]):
        start_line, start_column, has_count, is_gap = segment
        end_line, end_column = segments[index + 1][:2]
        if not has_count or is_gap:
            continue
        if (end_line, end_column) <= (start_line, start_column):
            continue
        final_line = end_line if end_column > 1 else end_line - 1
        executable.update(range(start_line, final_line + 1))

    if segments and segments[-1][2] and not segments[-1][3]:
        raise CoverageDataError(
            f"LLVM JSON has an unterminated executable segment for "
            f"{entry.get('filename', '<unknown>')}"
        )
    return executable


def json_executable_lines(
    document: dict[str, Any],
    source_root: Path,
    exclusions: set[str],
) -> dict[str, set[int]]:
    root = normalized_path(source_root).rstrip("/") + "/"
    data_sets = document.get("data")
    if not isinstance(data_sets, list):
        raise CoverageDataError("LLVM coverage JSON has no data sets")

    files: dict[str, set[int]] = {}
    for data_set in data_sets:
        if not isinstance(data_set, dict) or not isinstance(data_set.get("files"), list):
            raise CoverageDataError("LLVM coverage JSON has an invalid files collection")
        for entry in data_set["files"]:
            if not isinstance(entry, dict):
                raise CoverageDataError("LLVM coverage JSON has an invalid file record")
            filename = normalized_path(str(entry.get("filename", "")))
            if (
                not filename.startswith(root)
                or not filename.endswith(".swift")
                or filename in exclusions
            ):
                continue
            if filename in files:
                raise CoverageDataError(
                    f"LLVM coverage JSON contains duplicate file data for {filename}"
                )
            files[filename] = executable_lines_from_segments(entry)
    return files


def production_files(
    files: dict[str, dict[int, int]],
    source_root: Path,
    exclusions: set[str],
) -> dict[str, dict[int, int]]:
    root = normalized_path(source_root).rstrip("/") + "/"
    return {
        filename: counts
        for filename, counts in files.items()
        if filename.startswith(root)
        and filename.endswith(".swift")
        and filename not in exclusions
    }


def aggregate_measurement(files: dict[str, dict[int, int]]) -> CoverageMeasurement:
    executable = sum(len(counts) for counts in files.values())
    covered = sum(
        1 for counts in files.values() for execution_count in counts.values() if execution_count
    )
    return CoverageMeasurement(covered, executable)


def production_source_inventory(
    source_root: Path,
    exclusions: set[str],
) -> set[str]:
    return {
        normalized_path(path)
        for path in source_root.rglob("*.swift")
        if normalized_path(path) not in exclusions
    }


def validate_production_line_coverage(
    files: dict[str, dict[int, int]],
    expected_executable_lines: dict[str, set[int]],
) -> None:
    for filename, counts in files.items():
        source_path = Path(filename)
        try:
            source_line_count = len(
                source_path.read_text(encoding="utf-8").splitlines()
            )
        except OSError as error:
            raise CoverageDataError(
                f"Unable to read production source covered by LCOV: {filename}"
            ) from error

        expected = expected_executable_lines.get(filename)
        if expected is None:
            raise CoverageDataError(
                f"Production source is absent from LLVM coverage JSON: {filename}"
            )
        if not expected:
            raise CoverageDataError(
                "LLVM coverage reports no executable physical lines for "
                f"production source: {filename}"
            )
        out_of_range = sorted(
            line
            for line in counts.keys() | expected
            if line < 1 or line > source_line_count
        )
        if out_of_range:
            raise CoverageDataError(
                f"LCOV has out-of-range physical lines for {filename}: "
                + ", ".join(map(str, out_of_range))
            )
        actual = set(counts)
        if actual != expected:
            missing = sorted(expected - actual)
            unexpected = sorted(actual - expected)
            details: list[str] = []
            if missing:
                details.append(
                    "missing executable lines " + ", ".join(map(str, missing))
                )
            if unexpected:
                details.append(
                    "unexpected executable lines " + ", ".join(map(str, unexpected))
                )
            raise CoverageDataError(
                f"LCOV physical-line data is incomplete or stale for {filename}: "
                + "; ".join(details)
            )


def changed_measurement(
    *,
    files: dict[str, dict[int, int]],
    changed: dict[str, set[int]],
    repository_root: Path,
    source_root: Path,
    exclusions: set[str],
) -> ChangedCoverage:
    root = normalized_path(source_root).rstrip("/") + "/"
    covered = 0
    executable = 0
    failures: list[str] = []
    uncovered: list[tuple[str, int]] = []

    for relative_path, changed_lines in changed.items():
        absolute_path = normalized_path(relative_path, repository_root)
        if (
            not absolute_path.startswith(root)
            or not absolute_path.endswith(".swift")
            or absolute_path in exclusions
        ):
            continue

        counts = files.get(absolute_path)
        if counts is None:
            failures.append(f"Changed package source is absent from coverage: {relative_path}")
            continue

        executable_changed = changed_lines & counts.keys()
        executable += len(executable_changed)
        for line in executable_changed:
            if counts[line] > 0:
                covered += 1
            else:
                uncovered.append((relative_path, line))

    return ChangedCoverage(
        CoverageMeasurement(covered, executable),
        tuple(failures),
        tuple(sorted(uncovered)),
    )


def coverage_label(ratio: float | None) -> str:
    return f"{ratio:.2f}%" if ratio is not None else "N/A"


def append_summary(lines: list[str]) -> None:
    body = "\n".join(lines) + "\n"
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write(body)
    else:
        print(body)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage-lcov", required=True, type=Path)
    parser.add_argument("--coverage-json", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--base-sha")
    parser.add_argument("--minimum", type=percentage, default=90.0)
    parser.add_argument("--changed-minimum", type=percentage, default=90.0)
    parser.add_argument(
        "--exclude-source",
        action="append",
        default=[],
        type=Path,
        help="Exact source file path to exclude from production coverage",
    )
    args = parser.parse_args()

    failures: list[str] = []
    exclusions = {normalized_path(path) for path in args.exclude_source}
    try:
        repository_root = Path(
            run("git", "rev-parse", "--show-toplevel").stdout.strip()
        ).resolve()
        all_files = parse_lcov(
            args.coverage_lcov.read_text(encoding="utf-8"),
            repository_root,
        )
        files = production_files(all_files, args.source_root, exclusions)
        json_lines = json_executable_lines(
            json.loads(args.coverage_json.read_text(encoding="utf-8")),
            args.source_root,
            exclusions,
        )
        validate_production_line_coverage(files, json_lines)
        aggregate = aggregate_measurement(files)
        source_inventory = production_source_inventory(
            args.source_root,
            exclusions,
        )
        missing_lcov_sources = sorted(source_inventory - files.keys())
        missing_json_sources = sorted(source_inventory - json_lines.keys())
        stale_lcov_sources = sorted(files.keys() - source_inventory)
        stale_json_sources = sorted(json_lines.keys() - source_inventory)
        base_sha = resolve_base_sha(args.base_sha)
    except (
        CoverageDataError,
        InvalidBaseSHAError,
        json.JSONDecodeError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    changed = ChangedCoverage(CoverageMeasurement(0, 0), (), ())
    if missing_lcov_sources:
        failures.append(
            "Production package sources are absent from LCOV: "
            + ", ".join(missing_lcov_sources)
        )
    if missing_json_sources:
        failures.append(
            "Production package sources are absent from LLVM coverage JSON: "
            + ", ".join(missing_json_sources)
        )
    if stale_lcov_sources:
        failures.append(
            "LCOV contains stale production sources: "
            + ", ".join(stale_lcov_sources)
        )
    if stale_json_sources:
        failures.append(
            "LLVM coverage JSON contains stale production sources: "
            + ", ".join(stale_json_sources)
        )
    if base_sha:
        try:
            changed_lines = changed_swift_lines(base_sha)
        except subprocess.CalledProcessError as error:
            detail = error.stderr.strip() if error.stderr else str(error)
            failures.append(f"Unable to diff changed Swift lines: {detail}")
            changed_lines = {}
        changed = changed_measurement(
            files=files,
            changed=changed_lines,
            repository_root=repository_root,
            source_root=args.source_root,
            exclusions=exclusions,
        )
        failures.extend(changed.failures)

    append_summary(
        [
            "## Swift package coverage",
            "",
            "| Scope | Covered / executable lines | Coverage | Required |",
            "|---|---:|---:|---:|",
            (
                f"| `{args.source_root}` | {aggregate.covered} / "
                f"{aggregate.executable} | {coverage_label(aggregate.ratio)} | "
                f"{args.minimum:.2f}% |"
            ),
            (
                f"| Changed executable lines | {changed.measurement.covered} / "
                f"{changed.measurement.executable} | "
                f"{coverage_label(changed.measurement.ratio)} | "
                f"{args.changed_minimum:.2f}% |"
            ),
            "",
            f"Diff base: `{base_sha or 'unavailable'}`",
            "",
        ]
    )

    if not files or aggregate.executable == 0:
        failures.append(f"no source coverage found below {args.source_root}")
    elif aggregate.ratio is not None and aggregate.ratio < args.minimum:
        failures.append(
            f"Swift package coverage {aggregate.ratio:.2f}% is below "
            f"{args.minimum:.2f}%"
        )

    if (
        changed.measurement.ratio is not None
        and changed.measurement.ratio < args.changed_minimum
    ):
        failures.append(
            f"Swift package changed-line coverage "
            f"{changed.measurement.ratio:.2f}% is below "
            f"{args.changed_minimum:.2f}%"
        )
        for relative_path, line in changed.uncovered_lines:
            print(
                f"::error file={relative_path},line={line}::"
                "Changed executable line is not covered"
            )

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

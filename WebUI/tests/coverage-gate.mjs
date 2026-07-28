#!/usr/bin/env node

import { readFile, readdir } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const DEFAULT_AGGREGATE_MINIMUM = 80;
const DEFAULT_CHANGED_MINIMUM = 90;

export class CoverageGateError extends Error {}

function normalizedPath(path) {
  return resolve(path).split(sep).join("/");
}

function git(arguments_, cwd, allowFailure = false) {
  const environment = { ...process.env };
  delete environment.GIT_DIR;
  delete environment.GIT_WORK_TREE;
  delete environment.GIT_INDEX_FILE;
  try {
    return execFileSync("git", arguments_, {
      cwd,
      encoding: "utf8",
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch (error) {
    if (allowFailure) {
      return null;
    }
    const detail = error.stderr?.toString().trim();
    throw new CoverageGateError(
      `git ${arguments_.join(" ")} failed${detail ? `: ${detail}` : ""}`,
    );
  }
}

export function parsePercentage(value, label) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 100) {
    throw new CoverageGateError(`${label} must be a finite number from 0 through 100.`);
  }
  return parsed;
}

export function isTriviaOnlyJavaScript(source) {
  let index = source.charCodeAt(0) === 0xfeff ? 1 : 0;
  if (source.startsWith("#!", index)) {
    const newline = source.indexOf("\n", index);
    index = newline === -1 ? source.length : newline + 1;
  }

  while (index < source.length) {
    if (/\s/u.test(source[index])) {
      index += 1;
      continue;
    }
    if (source.startsWith("//", index)) {
      const newline = source.indexOf("\n", index + 2);
      index = newline === -1 ? source.length : newline + 1;
      continue;
    }
    if (source.startsWith("/*", index)) {
      const end = source.indexOf("*/", index + 2);
      if (end === -1) {
        throw new CoverageGateError("A production JavaScript file has an unterminated comment.");
      }
      index = end + 2;
      continue;
    }
    return false;
  }
  return true;
}

/**
 * Parse LCOV DA records as physical executable lines.
 *
 * Multiple records for the same source/line are combined. A line is covered
 * when at least one record reports a positive execution count.
 */
export function parseLcov(text) {
  const records = new Map();
  let currentRecord = null;
  let sawSource = false;

  function declaredCount(line, label) {
    const match = new RegExp(`^${label}:(\\d+)$`, "u").exec(line);
    const value = match === null ? Number.NaN : Number(match[1]);
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new CoverageGateError(`Invalid LCOV ${label} record: ${line}`);
    }
    return value;
  }

  function finishRecord() {
    if (currentRecord === null) {
      throw new CoverageGateError("LCOV contains end_of_record without an active SF record.");
    }
    const { source, lines, linesFound, linesHit } = currentRecord;
    if (linesFound === null || linesHit === null) {
      const missing = [
        linesFound === null ? "LF" : null,
        linesHit === null ? "LH" : null,
      ].filter(Boolean);
      throw new CoverageGateError(
        `LCOV source ${source} is missing ${missing.join(" and ")}.`,
      );
    }
    if (lines.size !== linesFound) {
      throw new CoverageGateError(
        `LCOV source ${source} declares LF:${linesFound} but contains `
          + `${lines.size} unique DA records.`,
      );
    }
    const observedHits = [...lines.values()].filter((count) => count > 0).length;
    if (observedHits !== linesHit) {
      throw new CoverageGateError(
        `LCOV source ${source} declares LH:${linesHit} but contains `
          + `${observedHits} covered DA records.`,
      );
    }

    const merged = records.get(source) ?? new Map();
    for (const [lineNumber, count] of lines) {
      merged.set(lineNumber, (merged.get(lineNumber) ?? 0) + count);
    }
    records.set(source, merged);
    currentRecord = null;
  }

  for (const rawLine of text.split(/\r?\n/u)) {
    const line = rawLine.trimEnd();
    if (line.startsWith("SF:")) {
      if (currentRecord !== null) {
        throw new CoverageGateError(
          `LCOV source ${currentRecord.source} is missing end_of_record.`,
        );
      }
      const source = line.slice(3);
      if (!source) {
        throw new CoverageGateError("LCOV contains an empty SF record.");
      }
      currentRecord = {
        source,
        lines: new Map(),
        linesFound: null,
        linesHit: null,
      };
      sawSource = true;
      continue;
    }
    if (line.startsWith("DA:")) {
      if (currentRecord === null) {
        throw new CoverageGateError("LCOV contains a DA record before its SF record.");
      }
      const match = /^DA:(\d+),(\d+)(?:,.*)?$/u.exec(line);
      if (!match) {
        throw new CoverageGateError(`Invalid LCOV physical-line record: ${line}`);
      }
      const lineNumber = Number(match[1]);
      const executionCount = Number(match[2]);
      if (
        !Number.isSafeInteger(lineNumber)
        || lineNumber < 1
        || !Number.isSafeInteger(executionCount)
        || executionCount < 0
      ) {
        throw new CoverageGateError(`Invalid LCOV physical-line record: ${line}`);
      }
      if (currentRecord.lines.has(lineNumber)) {
        throw new CoverageGateError(
          `LCOV source ${currentRecord.source} repeats DA line ${lineNumber}.`,
        );
      }
      currentRecord.lines.set(lineNumber, executionCount);
      continue;
    }
    if (line.startsWith("LF:")) {
      if (currentRecord === null) {
        throw new CoverageGateError("LCOV contains an LF record before its SF record.");
      }
      if (currentRecord.linesFound !== null) {
        throw new CoverageGateError(
          `LCOV source ${currentRecord.source} contains multiple LF records.`,
        );
      }
      currentRecord.linesFound = declaredCount(line, "LF");
      continue;
    }
    if (line.startsWith("LH:")) {
      if (currentRecord === null) {
        throw new CoverageGateError("LCOV contains an LH record before its SF record.");
      }
      if (currentRecord.linesHit !== null) {
        throw new CoverageGateError(
          `LCOV source ${currentRecord.source} contains multiple LH records.`,
        );
      }
      currentRecord.linesHit = declaredCount(line, "LH");
      continue;
    }
    if (line === "end_of_record") {
      finishRecord();
    }
  }

  if (!sawSource) {
    throw new CoverageGateError("LCOV does not contain any source-file records.");
  }
  if (currentRecord !== null) {
    throw new CoverageGateError(
      `LCOV source ${currentRecord.source} is missing end_of_record.`,
    );
  }
  return records;
}

export function parseChangedLines(diff) {
  const changed = new Map();
  let currentPath = null;

  for (const line of diff.split(/\r?\n/u)) {
    if (line.startsWith("+++ ")) {
      const candidate = line.slice(4);
      currentPath =
        candidate === "/dev/null"
          ? null
          : candidate.startsWith("b/")
            ? candidate.slice(2)
            : candidate;
      if (currentPath !== null && !changed.has(currentPath)) {
        changed.set(currentPath, new Set());
      }
      continue;
    }
    if (currentPath === null || !line.startsWith("@@")) {
      continue;
    }
    const match = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/u.exec(line);
    if (!match) {
      throw new CoverageGateError(`Invalid unified-diff hunk: ${line}`);
    }
    const start = Number(match[1]);
    const count = Number(match[2] ?? "1");
    for (let offset = 0; offset < count; offset += 1) {
      changed.get(currentPath).add(start + offset);
    }
  }
  return changed;
}

async function productionSources(projectRoot, repositoryRoot) {
  const sourceRoot = resolve(projectRoot, "src");
  const sourceFiles = [];

  async function collect(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const path = resolve(directory, entry.name);
      if (entry.isDirectory()) {
        await collect(path);
      } else if (entry.isFile() && entry.name.endsWith(".js")) {
        sourceFiles.push(path);
      }
    }
  }

  await collect(sourceRoot);
  const sources = [];

  for (const absolutePath of sourceFiles) {
    const contents = await readFile(absolutePath, "utf8");
    sources.push({
      absolutePath: normalizedPath(absolutePath),
      repositoryPath: relative(repositoryRoot, absolutePath).split(sep).join("/"),
      projectPath: relative(projectRoot, absolutePath).split(sep).join("/"),
      contents,
      lineCount: contents.split(/\r?\n/u).length,
      triviaOnly: isTriviaOnlyJavaScript(contents),
    });
  }

  sources.sort((left, right) => left.repositoryPath.localeCompare(right.repositoryPath));
  if (sources.length === 0) {
    throw new CoverageGateError(`No production JavaScript sources found in ${sourceRoot}.`);
  }
  return sources;
}

function matchLcovSource(sourceField, sources, projectRoot, repositoryRoot, workingDirectory) {
  const normalizedField = sourceField.replaceAll("\\", "/");
  const directCandidates = new Set(
    [
      isAbsolute(sourceField) ? normalizedPath(sourceField) : null,
      normalizedPath(resolve(projectRoot, sourceField)),
      normalizedPath(resolve(repositoryRoot, sourceField)),
      normalizedPath(resolve(workingDirectory, sourceField)),
    ].filter(Boolean),
  );
  let matches = sources.filter(
    (source) =>
      directCandidates.has(source.absolutePath)
      || normalizedField === source.repositoryPath
      || normalizedField === source.projectPath
      || normalizedField.endsWith(`/${source.repositoryPath}`)
      || normalizedField.endsWith(`/${source.projectPath}`),
  );
  matches = [...new Map(matches.map((source) => [source.absolutePath, source])).values()];
  if (matches.length > 1) {
    throw new CoverageGateError(`LCOV source path is ambiguous: ${sourceField}`);
  }
  return matches[0] ?? null;
}

function attachCoverage(records, sources, projectRoot, repositoryRoot, workingDirectory) {
  const coverageByPath = new Map();
  const seenPaths = new Set();

  for (const [sourceField, recordLines] of records) {
    const source = matchLcovSource(
      sourceField,
      sources,
      projectRoot,
      repositoryRoot,
      workingDirectory,
    );
    if (source === null) {
      continue;
    }
    seenPaths.add(source.absolutePath);
    const target = coverageByPath.get(source.absolutePath) ?? new Map();
    for (const [lineNumber, count] of recordLines) {
      if (lineNumber > source.lineCount) {
        throw new CoverageGateError(
          `LCOV is stale for ${source.repositoryPath}: line ${lineNumber} exceeds `
            + `${source.lineCount} physical source lines.`,
        );
      }
      target.set(lineNumber, (target.get(lineNumber) ?? 0) + count);
    }
    coverageByPath.set(source.absolutePath, target);
  }

  const omissions = [];
  for (const source of sources) {
    const lineCoverage = coverageByPath.get(source.absolutePath);
    if (!seenPaths.has(source.absolutePath)) {
      if (!source.triviaOnly) {
        omissions.push(`${source.repositoryPath} is absent from LCOV`);
      }
      coverageByPath.set(source.absolutePath, new Map());
    } else if (lineCoverage.size === 0 && !source.triviaOnly) {
      omissions.push(`${source.repositoryPath} has no LCOV physical-line records`);
    }
  }
  if (omissions.length > 0) {
    throw new CoverageGateError(
      `Incomplete WebUI coverage instrumentation:\n  - ${omissions.join("\n  - ")}`,
    );
  }
  return coverageByPath;
}

function measurement(covered, executable) {
  return {
    covered,
    executable,
    percentage: executable === 0 ? null : (covered / executable) * 100,
  };
}

export function evaluateCoverage(sources, coverageByPath, changedByRepositoryPath) {
  let aggregateCovered = 0;
  let aggregateExecutable = 0;
  let changedCovered = 0;
  let changedExecutable = 0;
  const uncoveredChangedLines = [];

  for (const source of sources) {
    const lineCoverage = coverageByPath.get(source.absolutePath) ?? new Map();
    const changedLines = changedByRepositoryPath.get(source.repositoryPath) ?? new Set();
    for (const [lineNumber, count] of lineCoverage) {
      aggregateExecutable += 1;
      if (count > 0) {
        aggregateCovered += 1;
      }
      if (!changedLines.has(lineNumber)) {
        continue;
      }
      changedExecutable += 1;
      if (count > 0) {
        changedCovered += 1;
      } else {
        uncoveredChangedLines.push(`${source.repositoryPath}:${lineNumber}`);
      }
    }
  }

  return {
    aggregate: measurement(aggregateCovered, aggregateExecutable),
    changed: measurement(changedCovered, changedExecutable),
    uncoveredChangedLines,
  };
}

function resolveBaseSha(requestedBase, repositoryRoot, environment) {
  const configured = requestedBase ?? environment.COVERAGE_BASE_SHA;
  if (configured !== undefined) {
    if (!configured || /^0+$/u.test(configured)) {
      throw new CoverageGateError(`Invalid coverage base SHA: ${JSON.stringify(configured)}.`);
    }
    const resolved = git(
      ["rev-parse", "--verify", "--end-of-options", `${configured}^{commit}`],
      repositoryRoot,
      true,
    );
    if (resolved === null) {
      throw new CoverageGateError(
        `Coverage base SHA does not resolve to a commit: ${configured}`,
      );
    }
    return resolved;
  }

  const ci = environment.CI;
  if (ci && !["0", "false", "no"].includes(ci.toLowerCase())) {
    throw new CoverageGateError(
      "CI requires --base-sha or COVERAGE_BASE_SHA for changed-line coverage.",
    );
  }
  const parent = git(
    ["rev-parse", "--verify", "--end-of-options", "HEAD^"],
    repositoryRoot,
    true,
  );
  if (parent === null) {
    throw new CoverageGateError(
      "No coverage base is available; provide --base-sha or COVERAGE_BASE_SHA.",
    );
  }
  return parent;
}

function formatMeasurement(value) {
  if (value.percentage === null) {
    return `${value.covered}/${value.executable} (no executable lines)`;
  }
  return `${value.covered}/${value.executable} (${value.percentage.toFixed(2)}%)`;
}

export async function runCoverageGate({
  lcovPath,
  projectRoot,
  repositoryRoot,
  baseSha,
  aggregateMinimum = DEFAULT_AGGREGATE_MINIMUM,
  changedMinimum = DEFAULT_CHANGED_MINIMUM,
  environment = process.env,
  workingDirectory = process.cwd(),
}) {
  const resolvedProjectRoot = resolve(projectRoot);
  const resolvedRepositoryRoot =
    repositoryRoot === undefined
      ? git(["rev-parse", "--show-toplevel"], resolvedProjectRoot)
      : resolve(repositoryRoot);
  if (!resolvedRepositoryRoot) {
    throw new CoverageGateError("Unable to locate the Git repository root.");
  }
  const aggregateThreshold = parsePercentage(aggregateMinimum, "Aggregate minimum");
  const changedThreshold = parsePercentage(changedMinimum, "Changed minimum");
  const resolvedBase = resolveBaseSha(baseSha, resolvedRepositoryRoot, environment);
  const sources = await productionSources(resolvedProjectRoot, resolvedRepositoryRoot);
  const report = parseLcov(await readFile(resolve(lcovPath), "utf8"));
  const coverageByPath = attachCoverage(
    report,
    sources,
    resolvedProjectRoot,
    resolvedRepositoryRoot,
    workingDirectory,
  );
  const projectRepositoryPath = relative(
    resolvedRepositoryRoot,
    resolvedProjectRoot,
  ).split(sep).join("/");
  if (
    projectRepositoryPath === ""
    || projectRepositoryPath === ".."
    || projectRepositoryPath.startsWith("../")
  ) {
    throw new CoverageGateError("The WebUI project root must be inside the Git repository.");
  }
  const sourcePath = `${projectRepositoryPath}/src`;
  const diff = git(
    [
      "-c",
      "core.quotePath=false",
      "diff",
      "--find-renames",
      "--diff-filter=ACMR",
      "--unified=0",
      "--no-color",
      `${resolvedBase}...HEAD`,
      "--",
      `:(glob)${sourcePath}/*.js`,
      `:(glob)${sourcePath}/**/*.js`,
    ],
    resolvedRepositoryRoot,
  );
  const changedLines = parseChangedLines(diff);
  const result = evaluateCoverage(sources, coverageByPath, changedLines);

  if (result.aggregate.executable === 0) {
    throw new CoverageGateError("LCOV contains zero production executable lines.");
  }
  const failures = [];
  if (result.aggregate.percentage < aggregateThreshold) {
    failures.push(
      `aggregate coverage ${result.aggregate.percentage.toFixed(2)}% is below `
        + `${aggregateThreshold.toFixed(2)}%`,
    );
  }
  if (
    result.changed.executable > 0
    && result.changed.percentage < changedThreshold
  ) {
    failures.push(
      `changed-line coverage ${result.changed.percentage.toFixed(2)}% is below `
        + `${changedThreshold.toFixed(2)}%`,
    );
  }

  return {
    ...result,
    aggregateThreshold,
    changedThreshold,
    baseSha: resolvedBase,
    failures,
  };
}

function parseArguments(arguments_, environment) {
  const scriptRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
  const options = {
    lcovPath: environment.WEBUI_LCOV_PATH ?? resolve(scriptRoot, "coverage/lcov.info"),
    projectRoot: scriptRoot,
    baseSha: undefined,
    aggregateMinimum:
      environment.WEBUI_AGGREGATE_COVERAGE_MINIMUM ?? DEFAULT_AGGREGATE_MINIMUM,
    changedMinimum:
      environment.WEBUI_CHANGED_COVERAGE_MINIMUM ?? DEFAULT_CHANGED_MINIMUM,
    environment,
  };
  const aliases = new Map([
    ["--aggregate-min", "aggregateMinimum"],
    ["--aggregate-minimum", "aggregateMinimum"],
    ["--aggregate-threshold", "aggregateMinimum"],
    ["--changed-min", "changedMinimum"],
    ["--changed-minimum", "changedMinimum"],
    ["--changed-threshold", "changedMinimum"],
    ["--lcov", "lcovPath"],
    ["--base-sha", "baseSha"],
    ["--project-root", "projectRoot"],
    ["--repository-root", "repositoryRoot"],
  ]);

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--help" || argument === "-h") {
      return { help: true };
    }
    const equalsIndex = argument.indexOf("=");
    const flag = equalsIndex === -1 ? argument : argument.slice(0, equalsIndex);
    const key = aliases.get(flag);
    if (key === undefined) {
      throw new CoverageGateError(`Unknown argument: ${argument}`);
    }
    const value =
      equalsIndex === -1 ? arguments_[index += 1] : argument.slice(equalsIndex + 1);
    if (value === undefined || value === "") {
      throw new CoverageGateError(`${flag} requires a value.`);
    }
    options[key] = value;
  }
  return options;
}

async function main() {
  const options = parseArguments(process.argv.slice(2), process.env);
  if (options.help) {
    process.stdout.write(
      "Usage: node tests/coverage-gate.mjs [options]\n"
        + "  --lcov PATH                 LCOV report (default: coverage/lcov.info)\n"
        + "  --base-sha SHA              Git base for base...HEAD changed lines\n"
        + "  --aggregate-minimum PERCENT Aggregate physical-line minimum (default: 80)\n"
        + "  --changed-minimum PERCENT   Changed executable-line minimum (default: 90)\n",
    );
    return;
  }

  const result = await runCoverageGate(options);
  process.stdout.write(
    `WebUI aggregate physical-line coverage: ${formatMeasurement(result.aggregate)} `
      + `(required ${result.aggregateThreshold.toFixed(2)}%)\n`,
  );
  if (result.changed.executable === 0) {
    process.stdout.write("WebUI changed coverage: no changed executable lines.\n");
  } else {
    process.stdout.write(
      `WebUI changed executable-line coverage: ${formatMeasurement(result.changed)} `
        + `(required ${result.changedThreshold.toFixed(2)}%)\n`,
    );
  }
  if (result.uncoveredChangedLines.length > 0) {
    const shown = result.uncoveredChangedLines.slice(0, 50);
    process.stdout.write(`Uncovered changed lines:\n  ${shown.join("\n  ")}\n`);
    if (shown.length < result.uncoveredChangedLines.length) {
      process.stdout.write(
        `  … and ${result.uncoveredChangedLines.length - shown.length} more\n`,
      );
    }
  }
  if (result.failures.length > 0) {
    throw new CoverageGateError(result.failures.join("; "));
  }
}

const invokedPath = process.argv[1] ? normalizedPath(process.argv[1]) : "";
if (invokedPath === normalizedPath(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    process.stderr.write(`WebUI coverage gate failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}

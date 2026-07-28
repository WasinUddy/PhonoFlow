import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  CoverageGateError,
  isTriviaOnlyJavaScript,
  parseChangedLines,
  parseLcov,
  parsePercentage,
  runCoverageGate,
} from "../coverage-gate.mjs";

function git(root, ...arguments_) {
  const environment = { ...process.env };
  delete environment.GIT_DIR;
  delete environment.GIT_WORK_TREE;
  delete environment.GIT_INDEX_FILE;
  return execFileSync("git", arguments_, {
    cwd: root,
    encoding: "utf8",
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

async function fixtureRepository() {
  const root = await mkdtemp(join(tmpdir(), "phonoflow-web-coverage-"));
  const sourceRoot = join(root, "WebUI", "src");
  await mkdir(sourceRoot, { recursive: true });
  git(root, "init", "-q");
  git(root, "config", "user.email", "coverage@example.invalid");
  git(root, "config", "user.name", "Coverage Gate");
  await writeFile(
    join(sourceRoot, "feature.js"),
    "export function value() {\n  return 1;\n}\n",
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "base");
  return {
    root,
    projectRoot: join(root, "WebUI"),
    sourceRoot,
    base: git(root, "rev-parse", "HEAD"),
  };
}

async function commit(root, message = "head") {
  git(root, "add", ".");
  git(root, "commit", "-qm", message);
}

async function writeLcov(root, records) {
  const path = join(root, "lcov.info");
  const text = records
    .map(
      ({ source, lines }) =>
        `TN:\nSF:${source}\n`
          + `${lines.map(([line, count]) => `DA:${line},${count}`).join("\n")}\n`
          + `LF:${lines.length}\n`
          + `LH:${lines.filter(([, count]) => count > 0).length}\n`
          + "end_of_record\n",
    )
    .join("");
  await writeFile(path, text);
  return path;
}

describe("WebUI physical-line coverage gate", () => {
  it("parses and combines LCOV physical-line execution counts", () => {
    const records = parseLcov(
      "TN:\nSF:src/a.js\nDA:2,0\nDA:3,1\nLF:2\nLH:1\nend_of_record\n"
        + "SF:src/a.js\nDA:2,4\nLF:1\nLH:1\nend_of_record\n",
    );

    expect([...records.get("src/a.js")]).toEqual([
      [2, 4],
      [3, 1],
    ]);
    expect(() => parseLcov("DA:1,1\n")).toThrow(CoverageGateError);
    expect(() => parseLcov("SF:a.js\nDA:0,1\n")).toThrow(CoverageGateError);
  });

  it("rejects mismatched counters and truncated LCOV records atomically", () => {
    expect(() =>
      parseLcov("SF:a.js\nDA:1,1\nLF:2\nLH:1\nend_of_record\n"),
    ).toThrow("declares LF:2 but contains 1 unique DA records");
    expect(() =>
      parseLcov("SF:a.js\nDA:1,1\nLF:1\nLH:0\nend_of_record\n"),
    ).toThrow("declares LH:0 but contains 1 covered DA records");
    expect(() =>
      parseLcov("SF:a.js\nDA:1,1\nLH:1\nend_of_record\n"),
    ).toThrow("is missing LF");
    expect(() =>
      parseLcov("SF:a.js\nDA:1,1\nLF:1\nLH:1\n"),
    ).toThrow("is missing end_of_record");
    expect(() =>
      parseLcov(
        "SF:a.js\nDA:1,1\nLF:1\nLH:1\n"
          + "SF:b.js\nDA:1,1\nLF:1\nLH:1\nend_of_record\n",
      ),
    ).toThrow("source a.js is missing end_of_record");
  });

  it("accepts only finite percentages in the closed interval", () => {
    expect(parsePercentage("90", "threshold")).toBe(90);
    for (const invalid of ["NaN", "Infinity", "-1", "101"]) {
      expect(() => parsePercentage(invalid, "threshold")).toThrow(CoverageGateError);
    }
  });

  it("recognizes blank, shebang, line-comment, and block-comment-only files", () => {
    expect(isTriviaOnlyJavaScript("\ufeff#!/usr/bin/env node\n// docs\n/* more */\n")).toBe(
      true,
    );
    expect(isTriviaOnlyJavaScript("// docs\nexport {};\n")).toBe(false);
    expect(() => isTriviaOnlyJavaScript("/* never ends")).toThrow(CoverageGateError);
  });

  it("parses added lines and ignores deletion-only hunks", () => {
    const changed = parseChangedLines(
      "+++ b/WebUI/src/a.js\n"
        + "@@ -1,0 +2,3 @@\n"
        + "@@ -8,2 +11,0 @@\n"
        + "+++ /dev/null\n"
        + "@@ -1 +0,0 @@\n",
    );

    expect([...changed.get("WebUI/src/a.js")]).toEqual([2, 3, 4]);
  });

  it("passes comment-only changes without inventing executable changed lines", async () => {
    const fixture = await fixtureRepository();
    const feature = join(fixture.sourceRoot, "feature.js");
    const comments = join(fixture.sourceRoot, "notes.js");
    await writeFile(feature, "// documentation\nexport function value() {\n  return 1;\n}\n");
    await writeFile(comments, "// This file intentionally contains only documentation.\n");
    await commit(fixture.root);
    const lcov = await writeLcov(fixture.root, [
      {
        source: feature,
        lines: [
          [2, 1],
          [3, 1],
        ],
      },
    ]);

    const result = await runCoverageGate({
      lcovPath: lcov,
      projectRoot: fixture.projectRoot,
      repositoryRoot: fixture.root,
      baseSha: fixture.base,
      aggregateMinimum: 100,
      changedMinimum: 100,
      environment: {},
    });

    expect(result.aggregate).toMatchObject({ covered: 2, executable: 2 });
    expect(result.changed).toMatchObject({ covered: 0, executable: 0 });
    expect(result.failures).toEqual([]);
  });

  it("counts every executable line in a new source and reports uncovered changes", async () => {
    const fixture = await fixtureRepository();
    const feature = join(fixture.sourceRoot, "feature.js");
    const nestedRoot = join(fixture.sourceRoot, "features");
    const added = join(nestedRoot, "added.js");
    await mkdir(nestedRoot);
    await writeFile(added, "export const answer = 42;\nexport const tested = true;\n");
    await commit(fixture.root);
    const lcov = await writeLcov(fixture.root, [
      {
        source: feature,
        lines: [
          [1, 1],
          [2, 1],
        ],
      },
      {
        source: added,
        lines: [
          [1, 0],
          [2, 1],
        ],
      },
    ]);

    const result = await runCoverageGate({
      lcovPath: lcov,
      projectRoot: fixture.projectRoot,
      repositoryRoot: fixture.root,
      baseSha: fixture.base,
      aggregateMinimum: 70,
      changedMinimum: 90,
      environment: {},
    });

    expect(result.aggregate).toMatchObject({ covered: 3, executable: 4 });
    expect(result.changed).toMatchObject({ covered: 1, executable: 2 });
    expect(result.uncoveredChangedLines).toEqual(["WebUI/src/features/added.js:1"]);
    expect(result.failures).toEqual([
      "changed-line coverage 50.00% is below 90.00%",
    ]);
  });

  it("fails closed when a production source is omitted from LCOV", async () => {
    const fixture = await fixtureRepository();
    await writeFile(join(fixture.sourceRoot, "omitted.js"), "export const omitted = true;\n");
    await commit(fixture.root);
    const lcov = await writeLcov(fixture.root, [
      {
        source: join(fixture.sourceRoot, "feature.js"),
        lines: [[1, 1]],
      },
    ]);

    await expect(
      runCoverageGate({
        lcovPath: lcov,
        projectRoot: fixture.projectRoot,
        repositoryRoot: fixture.root,
        baseSha: fixture.base,
        environment: {},
      }),
    ).rejects.toThrow("omitted.js is absent from LCOV");
  });

  it("requires an explicit valid base in CI", async () => {
    const fixture = await fixtureRepository();
    await writeFile(join(fixture.sourceRoot, "feature.js"), "export const changed = true;\n");
    await commit(fixture.root);
    const lcov = await writeLcov(fixture.root, [
      {
        source: join(fixture.sourceRoot, "feature.js"),
        lines: [[1, 1]],
      },
    ]);

    await expect(
      runCoverageGate({
        lcovPath: lcov,
        projectRoot: fixture.projectRoot,
        repositoryRoot: fixture.root,
        environment: { CI: "true" },
      }),
    ).rejects.toThrow("CI requires --base-sha or COVERAGE_BASE_SHA");
    await expect(
      runCoverageGate({
        lcovPath: lcov,
        projectRoot: fixture.projectRoot,
        repositoryRoot: fixture.root,
        baseSha: "0".repeat(40),
        environment: {},
      }),
    ).rejects.toThrow("Invalid coverage base SHA");
  });
});

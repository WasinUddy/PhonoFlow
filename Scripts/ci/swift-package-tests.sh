#!/bin/bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 "$repo_root/Scripts/ci/test_coverage_gates.py"

manifest_list="$(mktemp "${TMPDIR:-/tmp}/phonoflow-package-manifests.XXXXXX")"
trap 'rm -f "$manifest_list"' EXIT

required_manifest="PhonoFlowCore/Package.swift"
if ! git ls-files --error-unmatch -- "$required_manifest" >/dev/null 2>&1; then
  echo "$required_manifest must be committed so clean CI checkouts test PhonoFlowCore." >&2
  exit 1
fi

git ls-files -z -- 'Package.swift' '**/Package.swift' \
  | while IFS= read -r -d '' manifest; do
      case "$manifest" in
        .build/*|*/.build/*|DerivedData/*|*/DerivedData/*)
          continue
          ;;
      esac
      printf '%s\n' "$manifest"
    done > "$manifest_list"

if [[ ! -s "$manifest_list" ]]; then
  echo "No tracked Package.swift was found. PhonoFlowCore must be a committed local Swift package." >&2
  exit 1
fi

package_index=0
while IFS= read -r manifest; do
  package_index=$((package_index + 1))
  package_path="$(dirname "$manifest")"
  if [[ "$package_path" == "." ]]; then
    package_path="$repo_root"
  else
    package_path="$repo_root/$package_path"
  fi

  scratch_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/phonoflow-swiftpm-${package_index}"

  echo "::group::Resolve $(realpath "$package_path")"
  swift package \
    --package-path "$package_path" \
    --scratch-path "$scratch_path" \
    --only-use-versions-from-resolved-file \
    resolve
  echo "::endgroup::"

  echo "::group::Test $(realpath "$package_path")"
  SWIFT_DETERMINISTIC_HASHING=1 \
    swift test \
      --package-path "$package_path" \
      --scratch-path "$scratch_path" \
      --configuration debug \
      --only-use-versions-from-resolved-file \
      --parallel \
      --enable-code-coverage \
      -Xswiftc -warnings-as-errors
  echo "::endgroup::"

  coverage_path="$(
    SWIFT_DETERMINISTIC_HASHING=1 \
      swift test \
        --package-path "$package_path" \
        --scratch-path "$scratch_path" \
        --configuration debug \
        --only-use-versions-from-resolved-file \
        --enable-code-coverage \
        --show-codecov-path \
        -Xswiftc -warnings-as-errors \
      | tail -n 1
  )"
  if [[ ! -f "$coverage_path" ]]; then
    echo "SwiftPM did not export LLVM coverage JSON at $coverage_path." >&2
    exit 1
  fi
  coverage_directory="$(dirname "$coverage_path")"
  profile_path="$coverage_directory/default.profdata"
  if [[ ! -f "$profile_path" ]]; then
    echo "SwiftPM did not export indexed coverage data at $profile_path." >&2
    exit 1
  fi

  binary_directory="$(
    swift build \
      --package-path "$package_path" \
      --scratch-path "$scratch_path" \
      --configuration debug \
      --only-use-versions-from-resolved-file \
      --show-bin-path
  )"
  test_binaries=()
  while IFS= read -r -d '' candidate; do
    test_binaries+=("$candidate")
  done < <(
    find "$binary_directory" \
      -type f \
      -path '*PackageTests.xctest/Contents/MacOS/*PackageTests' \
      -perm -111 \
      -print0
  )
  if [[ "${#test_binaries[@]}" -ne 1 ]]; then
    echo "Expected one SwiftPM package test executable; found ${#test_binaries[@]}." >&2
    printf 'Candidate: %s\n' "${test_binaries[@]}" >&2
    exit 1
  fi

  lcov_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/phonoflow-swiftpm-${package_index}.lcov"
  xcrun llvm-cov export \
    --format=lcov \
    --check-binary-ids \
    --instr-profile "$profile_path" \
    "${test_binaries[0]}" > "$lcov_path"

  coverage_gate_arguments=(
    --coverage-lcov "$lcov_path"
    --coverage-json "$coverage_path"
    --source-root "$package_path/Sources"
    --minimum "${SWIFTPM_COVERAGE_MINIMUM:-90}"
    --changed-minimum "${SWIFTPM_CHANGED_COVERAGE_MINIMUM:-90}"
  )
  if [[ -n "${COVERAGE_BASE_SHA:-}" ]] && [[ ! "${COVERAGE_BASE_SHA}" =~ ^0+$ ]]; then
    coverage_gate_arguments+=(--base-sha "$COVERAGE_BASE_SHA")
  fi

  benchmark_source="$package_path/Sources/PhonoFlowBenchmarks/main.swift"
  if [[ -f "$benchmark_source" ]]; then
    coverage_gate_arguments+=(--exclude-source "$benchmark_source")
  fi

  Scripts/ci/swiftpm-coverage-gate.py "${coverage_gate_arguments[@]}"
done < "$manifest_list"

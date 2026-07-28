#!/bin/bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
output_path="${1:-}"
iterations="${PHONOFLOW_BENCHMARK_ITERATIONS:-5}"

if [[ -z "$output_path" ]]; then
  echo "Usage: $0 <output.json>" >&2
  exit 2
fi

mkdir -p "$(dirname "$output_path")"

manifest=""
while IFS= read -r candidate; do
  if grep -q 'PhonoFlowBenchmarks' "$repo_root/$candidate"; then
    manifest="$candidate"
    break
  fi
done < <(git -C "$repo_root" ls-files -- 'Package.swift' '**/Package.swift')

if [[ -z "$manifest" ]]; then
  while IFS= read -r candidate; do
    relative="${candidate#"$repo_root"/}"
    if grep -q 'PhonoFlowBenchmarks' "$candidate"; then
      manifest="$relative"
      break
    fi
  done < <(
    find "$repo_root" \
      -path '*/.build' -prune -o \
      -path '*/DerivedData' -prune -o \
      -name Package.swift -type f -print
  )
fi

if [[ -z "$manifest" ]]; then
  echo "A Swift package executable target named PhonoFlowBenchmarks is required." >&2
  exit 1
fi

package_path="$repo_root/$(dirname "$manifest")"
if [[ "$(dirname "$manifest")" == "." ]]; then
  package_path="$repo_root"
fi
scratch_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/phonoflow-benchmarks"

python3 "$repo_root/Scripts/ci/test-benchmark-validation.py"

SWIFT_DETERMINISTIC_HASHING=1 \
  swift run \
    --package-path "$package_path" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --only-use-versions-from-resolved-file \
    -Xswiftc -warnings-as-errors \
    PhonoFlowBenchmarks \
    --output "$output_path" \
    --iterations "$iterations"

python3 -m json.tool "$output_path" >/dev/null

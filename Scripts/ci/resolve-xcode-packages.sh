#!/bin/bash

set -euo pipefail

source_packages_path="${1:-}"
if [[ -z "$source_packages_path" ]]; then
  echo "Usage: $0 <cloned-source-packages-directory>" >&2
  exit 2
fi

if ! git ls-files -- 'Package.resolved' '**/Package.resolved' | grep -q .; then
  echo "At least one Package.resolved must be committed for reproducible Xcode builds." >&2
  exit 1
fi

xcodebuild -resolvePackageDependencies \
  -project PhonoFlow.xcodeproj \
  -scheme PhonoFlow \
  -clonedSourcePackagesDirPath "$source_packages_path" \
  -onlyUsePackageVersionsFromResolvedFile

resolution_changes="$(
  git status --porcelain --untracked-files=all -- 'Package.resolved' '**/Package.resolved'
)"
if [[ -n "$resolution_changes" ]]; then
  echo "Locked package resolution changed during dependency resolution:" >&2
  echo "$resolution_changes" >&2
  exit 1
fi

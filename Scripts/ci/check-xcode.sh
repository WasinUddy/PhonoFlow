#!/bin/bash

set -euo pipefail

expected_version="${PHONOFLOW_XCODE_VERSION:-26.4}"
expected_developer_dir="/Applications/Xcode_${expected_version}.app/Contents/Developer"

if [[ "${DEVELOPER_DIR:-}" != "$expected_developer_dir" ]]; then
  echo "DEVELOPER_DIR must be $expected_developer_dir (got ${DEVELOPER_DIR:-<unset>})." >&2
  exit 1
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode ${expected_version} is not installed at $DEVELOPER_DIR." >&2
  ls -1d /Applications/Xcode*.app 2>/dev/null || true
  exit 1
fi

actual_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
if [[ ! "$actual_version" =~ ^${expected_version//./\\.}([.][0-9]+)?$ ]]; then
  echo "Expected Xcode ${expected_version}, but xcodebuild reports ${actual_version}." >&2
  exit 1
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ ! "$sdk_version" =~ ^${expected_version//./\\.}([.][0-9]+)?$ ]]; then
  echo "Expected macOS SDK ${expected_version}.x, but xcrun reports ${sdk_version}." >&2
  exit 1
fi

xcodebuild -version
swift --version
echo "macOS SDK ${sdk_version}"

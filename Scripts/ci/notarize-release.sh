#!/bin/bash

set -euo pipefail
umask 077

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${VERSION:?VERSION is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${RELEASE_SIGNING_IDENTITY:?RELEASE_SIGNING_IDENTITY is required}"
: "${APPLE_NOTARY_KEY_P8_BASE64:?APPLE_NOTARY_KEY_P8_BASE64 is required}"
: "${APPLE_NOTARY_KEY_ID:?APPLE_NOTARY_KEY_ID is required}"
: "${APPLE_NOTARY_ISSUER_ID:?APPLE_NOTARY_ISSUER_ID is required}"

readonly expected_bundle_id="com.wasinuddy.PhonoFlow"
readonly expected_executable="PhonoFlow"

fail() {
  echo "$*" >&2
  exit 1
}

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  fail "VERSION must be stable SemVer (MAJOR.MINOR.PATCH)."
fi
if [[ ! "$GITHUB_RUN_NUMBER" =~ ^(0|[1-9][0-9]*)$ ]]; then
  fail "GITHUB_RUN_NUMBER must be a decimal build number."
fi
if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  fail "APPLE_TEAM_ID must be a 10-character Apple team identifier."
fi
if [[ ! "$RELEASE_SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
  fail "RELEASE_SIGNING_IDENTITY must be an uppercase SHA-1 identity hash."
fi
if [[ ! "$APPLE_NOTARY_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  fail "APPLE_NOTARY_KEY_ID must be a 10-character App Store Connect key ID."
fi
if [[ ! "$APPLE_NOTARY_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  fail "APPLE_NOTARY_ISSUER_ID must be a UUID."
fi

canonical_directory() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import stat
import sys

supplied = os.path.abspath(sys.argv[1])
if "\n" in supplied or "\r" in supplied:
    raise SystemExit("Directory path must not contain newlines")
if os.path.islink(supplied):
    raise SystemExit(f"Refusing symlink directory {supplied!r}")
path = os.path.realpath(supplied)
try:
    mode = os.stat(path, follow_symlinks=False).st_mode
except OSError as error:
    raise SystemExit(f"Unable to inspect directory {path!r}: {error}")
if not stat.S_ISDIR(mode):
    raise SystemExit(f"Expected a directory, got {path!r}")
print(path)
PY
}

canonical_contained_path() {
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import os
import stat
import sys

root = os.path.realpath(os.path.abspath(sys.argv[1]))
supplied = os.path.abspath(sys.argv[2])
kind = sys.argv[3]
if "\n" in supplied or "\r" in supplied:
    raise SystemExit("Artifact path must not contain newlines")
if os.path.islink(supplied):
    raise SystemExit(f"Refusing symlink path {supplied!r}")
cursor = supplied
components = []
while os.path.realpath(cursor) != root:
    parent = os.path.dirname(cursor)
    if parent == cursor:
        raise SystemExit(f"Path is not a child of the trusted root: {supplied!r}")
    components.append(os.path.basename(cursor))
    cursor = parent
current = cursor
for component in reversed(components):
    current = os.path.join(current, component)
    if os.path.islink(current):
        raise SystemExit(f"Refusing symlink path component {current!r}")
path = os.path.realpath(supplied)
try:
    relative = os.path.relpath(path, root)
    if relative == os.pardir or relative.startswith(os.pardir + os.sep) or relative == ".":
        raise SystemExit(f"Path is not a child of the trusted root: {supplied!r}")
except ValueError:
    raise SystemExit(f"Path is not a child of the trusted root: {supplied!r}")
current = root
for component in relative.split(os.sep):
    current = os.path.join(current, component)
    if os.path.islink(current):
        raise SystemExit(f"Refusing symlink path component {current!r}")
try:
    mode = os.stat(path, follow_symlinks=False).st_mode
except OSError as error:
    raise SystemExit(f"Unable to inspect {path!r}: {error}")
if kind == "file" and not stat.S_ISREG(mode):
    raise SystemExit(f"Expected a regular file, got {path!r}")
if kind == "directory" and not stat.S_ISDIR(mode):
    raise SystemExit(f"Expected a directory, got {path!r}")
print(path)
PY
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print tolower($1)}'
}

directory_digest() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
digest = hashlib.sha256()
for current_root, directories, files in os.walk(root, followlinks=False):
    directories.sort()
    files.sort()
    for name in directories:
        path = os.path.join(current_root, name)
        if os.path.islink(path):
            raise SystemExit(f"Refusing symlink in dSYM: {path}")
        relative = os.path.relpath(path, root).encode("utf-8", "surrogateescape")
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISDIR(mode):
            raise SystemExit(f"Unexpected non-directory dSYM content: {path}")
        digest.update(b"D")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update((mode & 0o777).to_bytes(4, "big"))
    for name in files:
        path = os.path.join(current_root, name)
        relative = os.path.relpath(path, root).encode("utf-8", "surrogateescape")
        if os.path.islink(path):
            raise SystemExit(f"Refusing symlink in dSYM: {path}")
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode):
            raise SystemExit(f"Unexpected non-regular dSYM content: {path}")
        digest.update(b"F")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update((mode & 0o777).to_bytes(4, "big"))
        digest.update(os.stat(path, follow_symlinks=False).st_size.to_bytes(8, "big"))
        with open(path, "rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
print(digest.hexdigest())
PY
}

exact_architectures() {
  local binary_path="$1"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$binary_path")"
  /usr/bin/python3 - "$architectures" <<'PY'
import sys

actual = sys.argv[1].split()
expected = ["arm64", "x86_64"]
if sorted(actual) != sorted(expected) or len(actual) != len(expected):
    raise SystemExit(f"Expected exactly arm64 and x86_64 slices, got {actual!r}")
PY
}

verify_signature_identity() {
  local code_path="$1"
  local details="$2"
  local require_hardened_runtime="${3:-1}"
  local architecture="${4:-}"
  local architecture_label="${architecture:-archive}"
  local architecture_arguments=()
  local certificate_prefix="$verification_path/certificate-${verification_index}-${architecture_label}-"
  local certificate_path="${certificate_prefix}0"
  local actual_identity

  if [[ -n "$architecture" ]]; then
    architecture_arguments=(--architecture "$architecture")
  fi
  verification_index=$((verification_index + 1))
  /usr/bin/codesign \
    --display \
    "${architecture_arguments[@]}" \
    --extract-certificates="$certificate_prefix" \
    "$code_path" \
    2>/dev/null
  [[ -f "$certificate_path" && ! -L "$certificate_path" ]] \
    || fail "Unable to extract the signing certificate from ${code_path}."
  actual_identity="$(
    /usr/bin/openssl x509 -inform DER -in "$certificate_path" -noout -fingerprint -sha1 \
      | /usr/bin/sed 's/^[^=]*=//' \
      | /usr/bin/tr -d ':' \
      | /usr/bin/tr '[:lower:]' '[:upper:]'
  )"
  [[ "$actual_identity" == "$RELEASE_SIGNING_IDENTITY" ]] \
    || fail "A finalized code object was not signed by the release identity."
  grep -Eq "^Authority=Developer ID Application: .+ \\(${APPLE_TEAM_ID}\\)$" <<<"$details" \
    || fail "A finalized code object has an unexpected signing authority."
  grep -Fxq "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$details" \
    || fail "A finalized code object has an unexpected team identifier."
  if [[ "$require_hardened_runtime" -eq 1 ]]; then
    grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details" \
      || fail "A finalized code object is missing hardened runtime."
  fi
  grep -Eq '^Timestamp=.+$' <<<"$details" \
    || fail "A finalized code object is missing a trusted timestamp."
}

verify_main_entitlements() {
  local app_path="$1"
  local architecture="$2"
  local entitlements_path="$verification_path/entitlements-${verification_index}-${architecture}.plist"
  verification_index=$((verification_index + 1))

  /usr/bin/codesign \
    --display \
    --architecture "$architecture" \
    --entitlements :- \
    "$app_path" \
    > "$entitlements_path" \
    2>/dev/null
  /usr/bin/plutil -lint "$entitlements_path" >/dev/null
  /usr/bin/python3 - "$entitlements_path" "$APPLE_TEAM_ID" "$expected_bundle_id" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
if not isinstance(entitlements, dict):
    raise SystemExit("Release entitlements are not a dictionary")
team_id, bundle_id = sys.argv[2:]
required = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.assets.music.read-write": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}
optional_identity = {
    "com.apple.application-identifier": f"{team_id}.{bundle_id}",
    "com.apple.developer.team-identifier": team_id,
}
allowed = set(required) | set(optional_identity)
unexpected = sorted(set(entitlements) - allowed)
if unexpected:
    raise SystemExit("Unexpected release entitlements: " + ", ".join(unexpected))
incorrect = sorted(
    key for key, value in required.items() if entitlements.get(key) is not value
)
incorrect.extend(
    key
    for key, value in optional_identity.items()
    if key in entitlements and entitlements[key] != value
)
if incorrect:
    raise SystemExit(
        "Missing or invalid release entitlements: " + ", ".join(sorted(incorrect))
    )
PY
}

verify_webui_assets() {
  local app_path="$1"
  /usr/bin/python3 - "$repository_root/WebUI" "$app_path/Contents/Resources/WebUI" <<'PY'
import hashlib
import os
import stat
import sys

source_root = os.path.realpath(sys.argv[1])
bundle_root = sys.argv[2]
expected = {
    "index.html", "styles.css", "src/api.js", "src/app.js",
    "src/live-audio.js", "src/spectrogram.js", "src/state.js", "src/view.js",
}
if os.path.islink(bundle_root):
    raise SystemExit("Bundled WebUI root must not be a symlink")
try:
    mode = os.stat(bundle_root, follow_symlinks=False).st_mode
except OSError as error:
    raise SystemExit(f"Bundled WebUI is unavailable: {error}")
if not stat.S_ISDIR(mode):
    raise SystemExit("Bundled WebUI root is not a directory")
actual = set()
for current_root, directories, files in os.walk(bundle_root, followlinks=False):
    for name in directories:
        if os.path.islink(os.path.join(current_root, name)):
            raise SystemExit("Bundled WebUI contains a directory symlink")
    for name in files:
        path = os.path.join(current_root, name)
        relative = os.path.relpath(path, bundle_root)
        if os.path.islink(path) or not stat.S_ISREG(os.stat(path, follow_symlinks=False).st_mode):
            raise SystemExit(f"Bundled WebUI asset is not a regular file: {relative}")
        actual.add(relative)
if actual != expected:
    raise SystemExit(
        f"Bundled WebUI inventory mismatch; missing={sorted(expected-actual)!r}, "
        f"extra={sorted(actual-expected)!r}"
    )
def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.digest()
for relative in sorted(expected):
    source = os.path.join(source_root, relative)
    bundled = os.path.join(bundle_root, relative)
    if os.path.islink(source) or not os.path.isfile(source):
        raise SystemExit(f"Source WebUI asset is unavailable: {relative}")
    if os.path.getsize(source) == 0 or os.path.getsize(bundled) == 0:
        raise SystemExit(f"WebUI asset is empty: {relative}")
    if digest(source) != digest(bundled):
        raise SystemExit(f"Bundled WebUI asset differs from source: {relative}")
PY
}

verify_bundle_filesystem() {
  local app_path="$1"
  /usr/bin/python3 - "$app_path" "$mach_o_manifest" <<'PY'
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
manifest_path = sys.argv[2]
mach_magics = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
unexpected_bundles = []
mach_objects = []
for current_root, directories, files in os.walk(root, followlinks=False):
    for name in list(directories):
        path = os.path.join(current_root, name)
        if os.path.islink(path):
            target = os.path.realpath(path)
            try:
                contained = os.path.commonpath((root, target)) == root
            except ValueError:
                contained = False
            if not contained:
                raise SystemExit(f"App bundle symlink escapes the bundle: {path}")
            directories.remove(name)
            continue
        if name.endswith((".app", ".appex", ".xpc")):
            unexpected_bundles.append(os.path.relpath(path, root))
    for name in files:
        path = os.path.join(current_root, name)
        if os.path.islink(path):
            target = os.path.realpath(path)
            try:
                contained = os.path.commonpath((root, target)) == root
            except ValueError:
                contained = False
            if not contained:
                raise SystemExit(f"App bundle symlink escapes the bundle: {path}")
            continue
        if not stat.S_ISREG(os.stat(path, follow_symlinks=False).st_mode):
            raise SystemExit(f"Unexpected non-regular app content: {path}")
        with open(path, "rb") as source:
            if source.read(4) in mach_magics:
                mach_objects.append(path)
if unexpected_bundles:
    raise SystemExit(
        "Unexpected nested executable bundles: " + ", ".join(unexpected_bundles)
    )
if not mach_objects:
    raise SystemExit("The app bundle does not contain Mach-O code")
with open(manifest_path, "wb") as manifest:
    for path in sorted(mach_objects):
        manifest.write(os.fsencode(path) + b"\0")
PY
}

verify_app() {
  local supplied_app_path="$1"
  local trusted_root="$2"
  local app_path
  local info_plist
  local executable_name
  local executable_path
  local signature_details
  local architecture
  local candidate
  local candidate_signature

  app_path="$(canonical_contained_path "$trusted_root" "$supplied_app_path" directory)"
  [[ "$(basename "$app_path")" == "PhonoFlow.app" ]] \
    || fail "The finalized application has an unexpected name."
  info_plist="$(canonical_contained_path "$app_path" "$app_path/Contents/Info.plist" file)"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "$expected_bundle_id" ]] \
    || fail "The finalized bundle identifier is unexpected."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$VERSION" ]] \
    || fail "The finalized application version does not match VERSION=${VERSION}."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$GITHUB_RUN_NUMBER" ]] \
    || fail "The finalized build number does not match GITHUB_RUN_NUMBER."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" == "APPL" ]] \
    || fail "The finalized bundle has an unexpected package type."
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
  [[ "$executable_name" == "$expected_executable" ]] \
    || fail "The finalized bundle has an unexpected executable name."
  executable_path="$(
    canonical_contained_path \
      "$app_path" \
      "$app_path/Contents/MacOS/$expected_executable" \
      file
  )"
  [[ -x "$executable_path" ]] || fail "The finalized executable is not executable."
  exact_architectures "$executable_path"

  /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"
  for architecture in arm64 x86_64; do
    signature_details="$(
      /usr/bin/codesign \
        --display \
        --architecture "$architecture" \
        --verbose=4 \
        "$app_path" \
        2>&1
    )"
    grep -Fxq "Identifier=${expected_bundle_id}" <<<"$signature_details" \
      || fail "The ${architecture} finalized app signature has an unexpected identifier."
    verify_signature_identity "$app_path" "$signature_details" 1 "$architecture"
    verify_main_entitlements "$app_path" "$architecture"
  done
  verify_webui_assets "$app_path"
  verify_bundle_filesystem "$app_path"

  while IFS= read -r -d '' candidate; do
    exact_architectures "$candidate"
    /usr/bin/codesign --verify --strict --verbose=2 "$candidate"
    for architecture in arm64 x86_64; do
      candidate_signature="$(
        /usr/bin/codesign \
          --display \
          --architecture "$architecture" \
          --verbose=4 \
          "$candidate" \
          2>&1
      )"
      verify_signature_identity "$candidate" "$candidate_signature" 1 "$architecture"
      if [[ "$candidate" != "$executable_path" ]]; then
        local nested_entitlements="$verification_path/nested-entitlements-${verification_index}-${architecture}.plist"
        verification_index=$((verification_index + 1))
        if ! /usr/bin/codesign \
          --display \
          --architecture "$architecture" \
          --entitlements :- \
          "$candidate" \
          > "$nested_entitlements" \
          2>/dev/null; then
          fail "Unable to inspect ${architecture} nested-code entitlements."
        fi
        if [[ -s "$nested_entitlements" ]]; then
          /usr/bin/python3 - "$nested_entitlements" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
if entitlements:
    raise SystemExit("Unexpected nested code entitlements: " + ", ".join(sorted(entitlements)))
PY
        fi
      fi
    done
  done < "$mach_o_manifest"
  verified_executable_path="$executable_path"
}

verify_dsym_matches() {
  local executable_path="$1"
  local dsym_path="$2"
  local app_uuids="$verification_path/app-uuids-${verification_index}.txt"
  local dsym_uuids="$verification_path/dsym-uuids-${verification_index}.txt"
  verification_index=$((verification_index + 1))

  /usr/bin/dwarfdump --uuid "$executable_path" > "$app_uuids"
  /usr/bin/dwarfdump --uuid "$dsym_path" > "$dsym_uuids"
  /usr/bin/python3 - "$app_uuids" "$dsym_uuids" <<'PY'
import re
import sys

pattern = re.compile(r"^UUID: ([0-9A-Fa-f-]{36}) \((arm64|x86_64)\) ")
def parse(path):
    values = {}
    with open(path, encoding="utf-8") as source:
        for line in source:
            match = pattern.match(line)
            if not match:
                raise SystemExit(f"Unexpected dwarfdump output: {line.rstrip()!r}")
            architecture = match.group(2)
            if architecture in values:
                raise SystemExit(f"Duplicate dSYM UUID for {architecture}")
            values[architecture] = match.group(1).upper()
    return values

app = parse(sys.argv[1])
dsym = parse(sys.argv[2])
expected = {"arm64", "x86_64"}
if set(app) != expected or set(dsym) != expected or app != dsym:
    raise SystemExit(f"App/dSYM UUID mismatch: app={app!r}, dSYM={dsym!r}")
PY
}

device_for_mount_from_plist() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    result = plistlib.load(source)
mount = os.path.realpath(sys.argv[2])
matches = [
    entity.get("dev-entry", "")
    for image in result.get("images", [])
    for entity in image.get("system-entities", [])
    if entity.get("mount-point") and os.path.realpath(entity["mount-point"]) == mount
]
if len(matches) > 1 or any(not value.startswith("/dev/") for value in matches):
    raise SystemExit(f"Ambiguous mounted release devices: {matches!r}")
if matches:
    print(matches[0])
PY
}

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
runner_temp="$(canonical_directory "$RUNNER_TEMP")"
github_output="$(canonical_contained_path "$runner_temp" "$GITHUB_OUTPUT" file)"

dmg_argument="${1:-}"
dsym_argument="${2:-}"
if [[ -z "$dmg_argument" || -z "$dsym_argument" ]]; then
  echo "Usage: $0 <signed.dmg> <PhonoFlow.app.dSYM>" >&2
  exit 2
fi
dmg_path="$(canonical_contained_path "$runner_temp" "$dmg_argument" file)"
dsym_path="$(canonical_contained_path "$runner_temp" "$dsym_argument" directory)"

release_path="$(dirname "$dmg_path")"
release_work_dir="$(dirname "$release_path")"
[[ "$(basename "$release_path")" == "release-assets" ]] \
  || fail "The DMG is not in the release-artifacts output directory."
[[ "$(dirname "$release_work_dir")" == "$runner_temp" ]] \
  || fail "The release work directory is not a direct child of RUNNER_TEMP."
[[ "$(basename "$release_work_dir")" =~ ^phonoflow-release\.[A-Za-z0-9]{6}$ ]] \
  || fail "The DMG is not from a private release-artifacts work directory."
[[ "$(basename "$dmg_path")" == "PhonoFlow-${VERSION}-macOS-universal.dmg" ]] \
  || fail "The signed DMG name does not match VERSION=${VERSION}."
expected_dsym_path="${release_work_dir}/PhonoFlow.xcarchive/dSYMs/PhonoFlow.app.dSYM"
[[ "$dsym_path" == "$(canonical_contained_path "$release_work_dir" "$expected_dsym_path" directory)" ]] \
  || fail "The dSYM is not paired with the supplied signed DMG."

notary_work_dir="$(/usr/bin/mktemp -d "${runner_temp}/phonoflow-notary.XXXXXX")"
notary_work_dir="$(canonical_contained_path "$runner_temp" "$notary_work_dir" directory)"
notary_work_identity="$(/usr/bin/stat -f '%d:%i' "$notary_work_dir")"
mount_path="${notary_work_dir}/mount"
verification_path="${notary_work_dir}/verification"
notary_key_path="${notary_work_dir}/notary-key.p8"
notary_result_path="${notary_work_dir}/notary-result.json"
notary_log_path="${notary_work_dir}/notary-log.json"
attach_result_path="${notary_work_dir}/attach.plist"
mach_o_manifest="${verification_path}/mach-o-files.bin"
mkdir -m 700 "$mount_path" "$verification_path"

mounted_device=""
attach_attempted=0
cleanup_notarization() {
  status=$?
  trap - EXIT
  set +e
  cleanup_status=0
  mount_cleanup_safe=1
  if [[ "$attach_attempted" -eq 1 && -z "$mounted_device" ]]; then
    cleanup_hdiutil_info="${verification_path}/cleanup-hdiutil-info.plist"
    if /usr/bin/hdiutil info -plist > "$cleanup_hdiutil_info" 2>/dev/null; then
      mounted_device="$(
        device_for_mount_from_plist "$cleanup_hdiutil_info" "$mount_path"
      )" || {
        cleanup_status=1
        mount_cleanup_safe=0
      }
    else
      cleanup_status=1
      mount_cleanup_safe=0
    fi
  fi
  if [[ -n "$mounted_device" ]]; then
    /usr/bin/hdiutil detach "$mounted_device" -quiet \
      || /usr/bin/hdiutil detach "$mounted_device" -force -quiet \
      || {
        cleanup_status=1
        mount_cleanup_safe=0
      }
  fi
  rm -f -- "$notary_key_path" || cleanup_status=1
  if [[ "$(/usr/bin/stat -f '%d:%i' "$notary_work_dir" 2>/dev/null)" \
    != "$notary_work_identity" ]]; then
    cleanup_status=1
    mount_cleanup_safe=0
  fi
  if [[ "$mount_cleanup_safe" -eq 1 && -d "$notary_work_dir" && ! -L "$notary_work_dir" ]]; then
    rm -rf -- "$notary_work_dir" || cleanup_status=1
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "Failed to detach the release image or remove notarization credentials." >&2
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup_notarization EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! printf '%s' "$APPLE_NOTARY_KEY_P8_BASE64" \
  | /usr/bin/python3 -c '
import base64
import binascii
import os
import sys

path = sys.argv[1]
try:
    encoded = b"".join(sys.stdin.buffer.read().split())
    decoded = base64.b64decode(encoded, validate=True)
except (binascii.Error, ValueError) as error:
    raise SystemExit(f"invalid base64: {error}")
if not decoded:
    raise SystemExit("decoded notarization key is empty")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(path, flags, 0o600)
with os.fdopen(descriptor, "wb") as destination:
    destination.write(decoded)
' "$notary_key_path"; then
  fail "APPLE_NOTARY_KEY_P8_BASE64 is not valid base64."
fi
[[ -s "$notary_key_path" && ! -L "$notary_key_path" ]] \
  || fail "The decoded notarization key is empty or unsafe."
unset APPLE_NOTARY_KEY_P8_BASE64

/usr/bin/codesign --verify --strict --verbose=4 "$dmg_path"
dmg_signature="$(/usr/bin/codesign -dv --verbose=4 "$dmg_path" 2>&1)"
verification_index=0
verify_signature_identity "$dmg_path" "$dmg_signature" 0
/usr/bin/hdiutil verify "$dmg_path"

pre_submit_sha256="$(sha256_file "$dmg_path")"
pre_submit_stat="$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")"
dsym_sha256="$(directory_digest "$dsym_path")"

set +e
submission_started_at="$(/bin/date +%s)"
/usr/bin/xcrun notarytool submit "$dmg_path" \
  --key "$notary_key_path" \
  --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --wait \
  --timeout 45m \
  --output-format json > "$notary_result_path"
notary_exit_code=$?
set -e
[[ -f "$notary_result_path" && ! -L "$notary_result_path" ]] \
  || fail "Notarization did not create a fresh regular result file."
[[ "$(/usr/bin/stat -f '%m' "$notary_result_path")" -ge "$submission_started_at" ]] \
  || fail "Notarization produced a stale result file."

submission_id="$(
  /usr/bin/python3 - "$notary_result_path" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source).get("id", "")
except (OSError, json.JSONDecodeError):
    value = ""
if isinstance(value, str) and re.fullmatch(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-"
    r"[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}",
    value,
):
    print(value)
PY
)"
log_exit_code=1
if [[ -n "$submission_id" ]]; then
  set +e
  /usr/bin/xcrun notarytool log "$submission_id" \
    --key "$notary_key_path" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    "$notary_log_path"
  log_exit_code=$?
  set -e
fi
rm -f -- "$notary_key_path"
[[ ! -e "$notary_key_path" && ! -L "$notary_key_path" ]] \
  || fail "The temporary notarization key could not be removed."

if [[ "$notary_exit_code" -ne 0 || "$log_exit_code" -ne 0 ]]; then
  [[ -f "$notary_result_path" ]] && cat "$notary_result_path" >&2
  [[ -f "$notary_log_path" ]] && cat "$notary_log_path" >&2
  if [[ "$notary_exit_code" -ne 0 ]]; then
    exit "$notary_exit_code"
  fi
  fail "The notarization log could not be downloaded."
fi
[[ -n "$submission_id" ]] || fail "Notarization did not return a valid submission ID."
[[ -f "$notary_log_path" && ! -L "$notary_log_path" ]] \
  || fail "Notarization did not create a fresh regular log file."
[[ "$(/usr/bin/stat -f '%m' "$notary_log_path")" -ge "$submission_started_at" ]] \
  || fail "Notarization produced a stale log file."
[[ "$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")" == "$pre_submit_stat" ]] \
  || fail "The signed DMG changed while notarization was running."
[[ "$(sha256_file "$dmg_path")" == "$pre_submit_sha256" ]] \
  || fail "The signed DMG hash changed while notarization was running."
[[ "$(directory_digest "$dsym_path")" == "$dsym_sha256" ]] \
  || fail "The dSYM changed while notarization was running."

/usr/bin/python3 \
  - "$notary_result_path" "$notary_log_path" "$submission_id" \
  "$(basename "$dmg_path")" "$pre_submit_sha256" <<'PY'
import json
import sys

result_path, log_path, submission_id, archive_name, expected_hash = sys.argv[1:]
with open(result_path, encoding="utf-8") as source:
    result = json.load(source)
with open(log_path, encoding="utf-8") as source:
    log = json.load(source)
if result.get("id") != submission_id:
    raise SystemExit("Notarization result ID does not match this submission")
if result.get("status") != "Accepted":
    raise SystemExit(
        f"Notarization status is {result.get('status')!r}, expected 'Accepted'"
    )
if log.get("jobId") != submission_id:
    raise SystemExit("Notarization log jobId does not match this submission")
if log.get("status") != "Accepted":
    raise SystemExit(f"Notarization log status is {log.get('status')!r}")
if log.get("archiveFilename") != archive_name:
    raise SystemExit(
        f"Notarization log archive is {log.get('archiveFilename')!r}, "
        f"expected {archive_name!r}"
    )
if str(log.get("sha256", "")).lower() != expected_hash:
    raise SystemExit("Notarization log SHA-256 does not match the submitted DMG")
issues = log.get("issues")
if issues not in (None, []):
    rendered = "; ".join(
        f"{issue.get('severity', 'unknown')}: {issue.get('message', issue)}"
        if isinstance(issue, dict) else str(issue)
        for issue in issues
    )
    raise SystemExit(f"Notarization log contains issues: {rendered}")
PY

/usr/bin/xcrun stapler staple -v "$dmg_path"
/usr/bin/xcrun stapler validate -v "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"
/usr/bin/codesign --verify --strict --verbose=4 "$dmg_path"
post_staple_signature="$(/usr/bin/codesign -dv --verbose=4 "$dmg_path" 2>&1)"
verify_signature_identity "$dmg_path" "$post_staple_signature" 0
post_staple_stat="$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")"
post_staple_sha256="$(sha256_file "$dmg_path")"
/usr/sbin/spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$dmg_path"

attach_attempted=1
/usr/bin/hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "$mount_path" \
  -plist \
  "$dmg_path" > "$attach_result_path"
mounted_device="$(
    /usr/bin/python3 - "$attach_result_path" "$mount_path" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    result = plistlib.load(source)
mount = os.path.realpath(sys.argv[2])
matches = [
    entity.get("dev-entry", "")
    for entity in result.get("system-entities", [])
    if entity.get("mount-point") and os.path.realpath(entity["mount-point"]) == mount
]
if len(matches) != 1 or not matches[0].startswith("/dev/"):
    raise SystemExit(f"Unable to identify the mounted release device: {matches!r}")
print(matches[0])
PY
)"
verified_executable_path=""
verify_app "$mount_path/PhonoFlow.app" "$mount_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$mount_path/PhonoFlow.app"
verify_dsym_matches "$verified_executable_path" "$dsym_path"
[[ "$(directory_digest "$dsym_path")" == "$dsym_sha256" ]] \
  || fail "The dSYM changed before final packaging."
/usr/bin/hdiutil detach "$mounted_device" -quiet
mounted_device=""
attach_attempted=0
[[ "$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")" == "$post_staple_stat" ]] \
  || fail "The stapled DMG changed during mounted verification."
[[ "$(sha256_file "$dmg_path")" == "$post_staple_sha256" ]] \
  || fail "The stapled DMG hash changed during mounted verification."

dsym_zip_path="${release_path}/PhonoFlow-${VERSION}-dSYMs.zip"
checksums_path="${release_path}/PhonoFlow-${VERSION}-SHA256SUMS.txt"
[[ ! -e "$dsym_zip_path" && ! -L "$dsym_zip_path" ]] \
  || fail "The dSYM archive output already exists."
[[ ! -e "$checksums_path" && ! -L "$checksums_path" ]] \
  || fail "The checksum output already exists."

temporary_dsym_zip="${notary_work_dir}/dSYMs.zip"
temporary_checksums="${notary_work_dir}/SHA256SUMS.txt"
/usr/bin/ditto -c -k --keepParent "$dsym_path" "$temporary_dsym_zip"
[[ -s "$temporary_dsym_zip" && ! -L "$temporary_dsym_zip" ]] \
  || fail "The dSYM archive was not created safely."
mv "$temporary_dsym_zip" "$dsym_zip_path"

(
  cd "$release_path"
  /usr/bin/shasum -a 256 \
    "$(basename "$dmg_path")" \
    "$(basename "$dsym_zip_path")" \
    > "$temporary_checksums"
  /usr/bin/shasum -a 256 -c "$temporary_checksums"
)
[[ -s "$temporary_checksums" && ! -L "$temporary_checksums" ]] \
  || fail "The checksum manifest was not created safely."
mv "$temporary_checksums" "$checksums_path"

{
  printf '%s\n' "dmg=${dmg_path}"
  printf '%s\n' "dsym=${dsym_zip_path}"
  printf '%s\n' "checksums=${checksums_path}"
} >> "$github_output"

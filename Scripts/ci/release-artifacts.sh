#!/bin/bash

set -euo pipefail
umask 077

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${VERSION:?VERSION is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${SIGNING_WORK_DIR:?SIGNING_WORK_DIR is required}"
: "${SIGNING_KEYCHAIN:?SIGNING_KEYCHAIN is required}"
: "${SIGNING_KEYCHAIN_PASSWORD:?SIGNING_KEYCHAIN_PASSWORD is required}"
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"
: "${RELEASE_SOURCE_PACKAGES:?RELEASE_SOURCE_PACKAGES is required}"

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
if [[ ! "$SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
  fail "SIGNING_IDENTITY must be an uppercase SHA-1 identity hash."
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
    if os.path.commonpath((root, path)) != root or path == root:
        raise SystemExit(f"Path is not a child of the trusted root: {supplied!r}")
except ValueError:
    raise SystemExit(f"Path is not a child of the trusted root: {supplied!r}")
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

exact_architectures() {
  local binary_path="$1"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$binary_path")"
  /usr/bin/python3 - "$architectures" <<'PY'
import sys

actual = sys.argv[1].split()
expected = ["arm64", "x86_64"]
if sorted(actual) != sorted(expected) or len(actual) != len(expected):
    raise SystemExit(
        f"Expected exactly arm64 and x86_64 slices, got {actual!r}"
    )
PY
}

bundle_content_digest() {
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
    for name in directories + files:
        path = os.path.join(current_root, name)
        relative = os.path.relpath(path, root).encode("utf-8", "surrogateescape")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        mode = os.lstat(path).st_mode
        digest.update((mode & 0o777).to_bytes(4, "big"))
        if stat.S_ISLNK(mode):
            target = os.readlink(path).encode("utf-8", "surrogateescape")
            digest.update(b"L" + len(target).to_bytes(8, "big") + target)
        elif stat.S_ISREG(mode):
            digest.update(b"F")
            size = os.stat(path, follow_symlinks=False).st_size
            digest.update(size.to_bytes(8, "big"))
            with open(path, "rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
        elif stat.S_ISDIR(mode):
            digest.update(b"D")
        else:
            raise SystemExit(f"Unexpected app bundle object: {path}")
print(digest.hexdigest())
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
  [[ "$actual_identity" == "$SIGNING_IDENTITY" ]] \
    || fail "A release code object was not signed by SIGNING_IDENTITY."

  grep -Eq "^Authority=Developer ID Application: .+ \\(${APPLE_TEAM_ID}\\)$" <<<"$details" \
    || fail "A release code object has an unexpected leaf signing authority."
  grep -Fxq "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$details" \
    || fail "A release code object has an unexpected team identifier."
  if [[ "$require_hardened_runtime" -eq 1 ]]; then
    grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details" \
      || fail "A release code object is missing hardened runtime."
  fi
  grep -Eq '^Timestamp=.+$' <<<"$details" \
    || fail "A release code object is missing a trusted timestamp."
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

team_id = sys.argv[2]
bundle_id = sys.argv[3]
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
    raise SystemExit(
        "Release export has unexpected entitlements: " + ", ".join(unexpected)
    )
incorrect = sorted(
    key for key, expected in required.items() if entitlements.get(key) is not expected
)
incorrect.extend(
    key
    for key, expected in optional_identity.items()
    if key in entitlements and entitlements[key] != expected
)
if incorrect:
    raise SystemExit(
        "Release export has missing or invalid entitlements: "
        + ", ".join(sorted(incorrect))
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
    "index.html",
    "styles.css",
    "src/api.js",
    "src/app.js",
    "src/live-audio.js",
    "src/spectrogram.js",
    "src/state.js",
    "src/view.js",
}
if os.path.islink(bundle_root):
    raise SystemExit("Bundled WebUI root must not be a symlink")
try:
    root_mode = os.stat(bundle_root, follow_symlinks=False).st_mode
except OSError as error:
    raise SystemExit(f"Bundled WebUI is unavailable: {error}")
if not stat.S_ISDIR(root_mode):
    raise SystemExit("Bundled WebUI root is not a directory")

actual = set()
for current_root, directories, files in os.walk(bundle_root, followlinks=False):
    for name in directories:
        path = os.path.join(current_root, name)
        if os.path.islink(path):
            raise SystemExit(f"Bundled WebUI contains a symlink: {path}")
    for name in files:
        path = os.path.join(current_root, name)
        relative = os.path.relpath(path, bundle_root)
        if os.path.islink(path):
            raise SystemExit(f"Bundled WebUI contains a symlink: {relative}")
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode):
            raise SystemExit(f"Bundled WebUI asset is not regular: {relative}")
        actual.add(relative)

if actual != expected:
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    raise SystemExit(
        f"Bundled WebUI inventory mismatch; missing={missing!r}, extra={extra!r}"
    )
for relative in sorted(expected):
    source = os.path.join(source_root, relative)
    bundled = os.path.join(bundle_root, relative)
    if os.path.islink(source) or not os.path.isfile(source):
        raise SystemExit(f"Source WebUI asset is unavailable: {relative}")
    if os.path.getsize(source) == 0 or os.path.getsize(bundled) == 0:
        raise SystemExit(f"WebUI asset is empty: {relative}")
    def digest(path):
        value = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
        return value.digest()
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
        mode = os.stat(path, follow_symlinks=False).st_mode
        if not stat.S_ISREG(mode):
            raise SystemExit(f"Unexpected non-regular app content: {path}")
        with open(path, "rb") as source:
            if source.read(4) in mach_magics:
                mach_objects.append(path)
if unexpected_bundles:
    raise SystemExit(
        "Unexpected nested executable bundles: " + ", ".join(unexpected_bundles)
    )
if not mach_objects:
    raise SystemExit("The app bundle does not contain any Mach-O code")
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
    || fail "The release application has an unexpected name."
  info_plist="$(canonical_contained_path "$app_path" "$app_path/Contents/Info.plist" file)"

  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "$expected_bundle_id" ]] \
    || fail "The release application bundle identifier is unexpected."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$VERSION" ]] \
    || fail "The release application version does not match VERSION=${VERSION}."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$GITHUB_RUN_NUMBER" ]] \
    || fail "The release application build does not match GITHUB_RUN_NUMBER."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" == "APPL" ]] \
    || fail "The release bundle has an unexpected package type."

  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
  [[ "$executable_name" == "$expected_executable" ]] \
    || fail "The release bundle has an unexpected executable name."
  executable_path="$(
    canonical_contained_path \
      "$app_path" \
      "$app_path/Contents/MacOS/$expected_executable" \
      file
  )"
  [[ -x "$executable_path" ]] || fail "The release executable is not executable."
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
      || fail "The ${architecture} app signature has an unexpected identifier."
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
if set(app) != expected or set(dsym) != expected:
    raise SystemExit(f"Expected exact universal UUID sets, got app={app!r}, dSYM={dsym!r}")
if app != dsym:
    raise SystemExit(f"App and dSYM UUIDs do not match: app={app!r}, dSYM={dsym!r}")
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
github_env="$(canonical_contained_path "$runner_temp" "$GITHUB_ENV" file)"
github_output="$(canonical_contained_path "$runner_temp" "$GITHUB_OUTPUT" file)"
source_packages_path="$(
  canonical_contained_path \
    "$runner_temp" \
    "$RELEASE_SOURCE_PACKAGES" \
    directory
)"
signing_work_dir="$(
  canonical_contained_path "$runner_temp" "$SIGNING_WORK_DIR" directory
)"
signing_keychain="$(
  canonical_contained_path "$signing_work_dir" "$SIGNING_KEYCHAIN" file
)"
[[ "$(dirname "$signing_work_dir")" == "$runner_temp" ]] \
  || fail "SIGNING_WORK_DIR is not a direct child of RUNNER_TEMP."
[[ "$(basename "$signing_work_dir")" =~ ^phonoflow-signing\.[A-Za-z0-9]{6}$ ]] \
  || fail "SIGNING_WORK_DIR has an unexpected name."
[[ "$signing_keychain" == "$signing_work_dir/signing.keychain-db" ]] \
  || fail "SIGNING_KEYCHAIN is not the expected imported keychain."
[[ "$(dirname "$source_packages_path")" == "$runner_temp" ]] \
  || fail "RELEASE_SOURCE_PACKAGES is not a direct child of RUNNER_TEMP."
[[ "$(basename "$source_packages_path")" =~ ^phonoflow-packages\.[A-Za-z0-9]{6}$ ]] \
  || fail "RELEASE_SOURCE_PACKAGES has an unexpected name."
source_packages_identity="$(/usr/bin/stat -f '%d:%i' "$source_packages_path")"

keychain_list_changed=0
keychain_deleted=0
mounted_device=""
attach_attempted=0
original_keychains=()
original_keychain_count=0

cleanup_release_build() {
  status=$?
  trap - EXIT
  set +e
  cleanup_status=0

  if [[ "$attach_attempted" -eq 1 && -z "$mounted_device" ]]; then
    cleanup_hdiutil_info="${verification_path}/cleanup-hdiutil-info.plist"
    if /usr/bin/hdiutil info -plist > "$cleanup_hdiutil_info" 2>/dev/null; then
      mounted_device="$(
        device_for_mount_from_plist "$cleanup_hdiutil_info" "$mount_path"
      )" || cleanup_status=1
    else
      cleanup_status=1
    fi
  fi
  if [[ -n "$mounted_device" ]]; then
    /usr/bin/hdiutil detach "$mounted_device" -quiet \
      || /usr/bin/hdiutil detach "$mounted_device" -force -quiet \
      || cleanup_status=1
  fi
  if [[ "$keychain_list_changed" -eq 1 ]]; then
    if [[ "$original_keychain_count" -gt 0 ]]; then
      /usr/bin/security list-keychains -d user -s "${original_keychains[@]}" \
        || cleanup_status=1
    else
      /usr/bin/security list-keychains -d user -s || cleanup_status=1
    fi
  fi
  /usr/bin/security lock-keychain "$signing_keychain" >/dev/null 2>&1 \
    || cleanup_status=1
  if /usr/bin/security delete-keychain "$signing_keychain" >/dev/null 2>&1; then
    keychain_deleted=1
  else
    cleanup_status=1
  fi
  if [[ "$keychain_deleted" -eq 1 ]]; then
    rmdir "$signing_work_dir" >/dev/null 2>&1 || cleanup_status=1
  fi

  printf '%s\n' "RELEASE_SIGNING_IDENTITY=${SIGNING_IDENTITY}" \
    >> "$github_env" \
    || cleanup_status=1
  if [[ "$keychain_deleted" -eq 1 && ! -e "$signing_work_dir" ]]; then
    {
      printf '%s\n' "SIGNING_WORK_DIR="
      printf '%s\n' "SIGNING_KEYCHAIN="
      printf '%s\n' "SIGNING_KEYCHAIN_PASSWORD="
      printf '%s\n' "SIGNING_IDENTITY="
    } >> "$github_env" || cleanup_status=1
  fi

  if [[ "$(/usr/bin/stat -f '%d:%i' "$source_packages_path" 2>/dev/null)" \
    != "$source_packages_identity" ]]; then
    cleanup_status=1
  elif [[ -d "$source_packages_path" && ! -L "$source_packages_path" ]]; then
    /bin/rm -rf -- "$source_packages_path" || cleanup_status=1
  fi

  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "Failed to restore the keychain search list or destroy release credentials." >&2
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup_release_build EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

keychain_list_output="$(/usr/bin/security list-keychains -d user)"
while IFS= read -r keychain_line; do
  keychain_line="${keychain_line#*\"}"
  keychain_line="${keychain_line%\"*}"
  if [[ -n "$keychain_line" ]]; then
    original_keychains+=("$keychain_line")
    original_keychain_count=$((original_keychain_count + 1))
  fi
done <<< "$keychain_list_output"

release_work_dir="$(/usr/bin/mktemp -d "${runner_temp}/phonoflow-release.XXXXXX")"
release_work_dir="$(canonical_contained_path "$runner_temp" "$release_work_dir" directory)"
archive_path="${release_work_dir}/PhonoFlow.xcarchive"
derived_data_path="${release_work_dir}/DerivedData"
export_path="${release_work_dir}/export"
export_options_path="${release_work_dir}/ExportOptions.plist"
release_path="${release_work_dir}/release-assets"
dmg_stage_path="${release_work_dir}/dmg-stage"
verification_path="${release_work_dir}/verification"
mount_path="${release_work_dir}/verify-mount"
mach_o_manifest="${verification_path}/mach-o-files.bin"
mkdir -m 700 "$release_path" "$dmg_stage_path" "$verification_path" "$mount_path"

/usr/bin/security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$signing_keychain"
unset SIGNING_KEYCHAIN_PASSWORD
keychain_list_changed=1
/usr/bin/security list-keychains -d user -s "$signing_keychain"

/usr/bin/xcodebuild archive \
  -project "$repository_root/PhonoFlow.xcodeproj" \
  -scheme PhonoFlow \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$source_packages_path" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

/usr/bin/python3 - "$export_options_path" "$SIGNING_IDENTITY" "$APPLE_TEAM_ID" <<'PY'
import os
import plistlib
import sys

path, identity, team_id = sys.argv[1:]
options = {
    "destination": "export",
    "method": "developer-id",
    "signingStyle": "manual",
    "signingCertificate": identity,
    "teamID": team_id,
    "stripSwiftSymbols": True,
    "thinning": "<none>",
}
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as destination:
    plistlib.dump(options, destination, fmt=plistlib.FMT_XML, sort_keys=True)
PY
/usr/bin/plutil -lint "$export_options_path" >/dev/null

/usr/bin/xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_path"

exported_app="$export_path/PhonoFlow.app"
[[ -d "$exported_app" && ! -L "$exported_app" ]] \
  || fail "The Developer ID export did not contain a regular PhonoFlow.app."
[[ ! -e "$dmg_stage_path/PhonoFlow.app" && ! -L "$dmg_stage_path/PhonoFlow.app" ]] \
  || fail "The private DMG stage unexpectedly contains an application."
/usr/bin/ditto "$exported_app" "$dmg_stage_path/PhonoFlow.app"
ln -s /Applications "$dmg_stage_path/Applications"

verification_index=0
verified_executable_path=""
verify_app "$dmg_stage_path/PhonoFlow.app" "$dmg_stage_path"
staged_executable="$verified_executable_path"
staged_bundle_digest="$(bundle_content_digest "$dmg_stage_path/PhonoFlow.app")"
dsym_path="$(
  canonical_contained_path \
    "$archive_path" \
    "$archive_path/dSYMs/PhonoFlow.app.dSYM" \
    directory
)"
verify_dsym_matches "$staged_executable" "$dsym_path"

dmg_path="${release_path}/PhonoFlow-${VERSION}-macOS-universal.dmg"
[[ ! -e "$dmg_path" && ! -L "$dmg_path" ]] \
  || fail "The release DMG output already exists."
/usr/bin/hdiutil create \
  -volname "PhonoFlow ${VERSION}" \
  -srcfolder "$dmg_stage_path" \
  -mode 755 \
  -uid 99 \
  -gid 99 \
  -format UDZO \
  -fs HFS+ \
  "$dmg_path"
[[ "$(bundle_content_digest "$dmg_stage_path/PhonoFlow.app")" == "$staged_bundle_digest" ]] \
  || fail "The staged app changed while the release image was created."

/usr/bin/codesign \
  --force \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  --keychain "$signing_keychain" \
  "$dmg_path"
/usr/bin/codesign --verify --strict --verbose=4 "$dmg_path"
dmg_signature="$(/usr/bin/codesign -dv --verbose=4 "$dmg_path" 2>&1)"
verify_signature_identity "$dmg_path" "$dmg_signature" 0
/usr/bin/hdiutil verify "$dmg_path"
dmg_pre_mount_stat="$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")"
dmg_pre_mount_sha256="$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print tolower($1)}')"

attach_result="${verification_path}/attach.plist"
attach_attempted=1
/usr/bin/hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "$mount_path" \
  -plist \
  "$dmg_path" > "$attach_result"
mounted_device="$(
    /usr/bin/python3 - "$attach_result" "$mount_path" <<'PY'
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
verify_app "$mount_path/PhonoFlow.app" "$mount_path"
mounted_executable="$verified_executable_path"
[[ "$(bundle_content_digest "$mount_path/PhonoFlow.app")" == "$staged_bundle_digest" ]] \
  || fail "The mounted release app differs from the validated staged app."
verify_dsym_matches "$mounted_executable" "$dsym_path"
/usr/bin/hdiutil detach "$mounted_device" -quiet
mounted_device=""
attach_attempted=0
[[ "$(/usr/bin/stat -f '%d:%i:%z' "$dmg_path")" == "$dmg_pre_mount_stat" ]] \
  || fail "The release DMG changed during mounted verification."
[[ "$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print tolower($1)}')" == "$dmg_pre_mount_sha256" ]] \
  || fail "The release DMG hash changed during mounted verification."

{
  printf '%s\n' "signed_dmg=${dmg_path}"
  printf '%s\n' "dsym_source=${dsym_path}"
} >> "$github_output"

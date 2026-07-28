#!/bin/bash

set -euo pipefail
umask 077

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

if [[ "${1:-}" == "--cleanup" ]]; then
  if [[ -z "${SIGNING_WORK_DIR:-}" && -z "${SIGNING_KEYCHAIN:-}" ]]; then
    exit 0
  fi
  : "${SIGNING_WORK_DIR:?SIGNING_WORK_DIR is required for cleanup}"
  : "${SIGNING_KEYCHAIN:?SIGNING_KEYCHAIN is required for cleanup}"

  validated_paths="$(
    /usr/bin/python3 - "$RUNNER_TEMP" "$SIGNING_WORK_DIR" "$SIGNING_KEYCHAIN" <<'PY'
import os
import re
import stat
import sys

root_supplied = os.path.abspath(sys.argv[1])
if os.path.islink(root_supplied):
    raise SystemExit("Refusing symlinked RUNNER_TEMP")
root = os.path.realpath(root_supplied)
work_supplied = os.path.abspath(sys.argv[2])
keychain_supplied = os.path.abspath(sys.argv[3])
if any("\n" in value or "\r" in value for value in sys.argv[1:]):
    raise SystemExit("Signing cleanup paths must not contain newlines")
if os.path.islink(work_supplied) or os.path.islink(keychain_supplied):
    raise SystemExit("Refusing symlinked signing cleanup paths")
work = os.path.realpath(work_supplied)
keychain = os.path.realpath(keychain_supplied)
try:
    if os.path.commonpath((root, work)) != root or work == root:
        raise SystemExit("Signing work directory escapes RUNNER_TEMP")
except ValueError:
    raise SystemExit("Signing work directory escapes RUNNER_TEMP")
if os.path.dirname(work) != root:
    raise SystemExit("Signing work directory must be a direct child of RUNNER_TEMP")
if not re.fullmatch(r"phonoflow-signing\.[A-Za-z0-9]{6}", os.path.basename(work)):
    raise SystemExit("Signing work directory has an unexpected name")
if keychain != os.path.join(work, "signing.keychain-db"):
    raise SystemExit("Signing keychain is not inside the signing work directory")
if not os.path.exists(work_supplied) and not os.path.islink(work_supplied):
    if os.path.exists(keychain_supplied) or os.path.islink(keychain_supplied):
        raise SystemExit("Signing keychain exists without its validated work directory")
    print("missing")
    print(work)
    print(keychain)
    raise SystemExit(0)
mode = os.stat(work, follow_symlinks=False).st_mode
if not stat.S_ISDIR(mode):
    raise SystemExit("Signing work path is not a directory")
if os.path.exists(keychain):
    keychain_mode = os.stat(keychain, follow_symlinks=False).st_mode
    if not stat.S_ISREG(keychain_mode):
        raise SystemExit("Signing keychain is not a regular file")
print("present")
print(work)
print(keychain)
PY
  )"
  validated_state="${validated_paths%%$'\n'*}"
  validated_paths="${validated_paths#*$'\n'}"
  validated_work_dir="${validated_paths%%$'\n'*}"
  validated_keychain="${validated_paths#*$'\n'}"
  if [[ "$validated_state" == "missing" ]]; then
    exit 0
  fi
  [[ "$validated_state" == "present" ]] \
    || {
      echo "Signing cleanup validation returned an unexpected state." >&2
      exit 1
    }

  if [[ -f "$validated_keychain" ]]; then
    if ! /usr/bin/security lock-keychain "$validated_keychain" >/dev/null 2>&1; then
      echo "The temporary signing keychain could not be locked; deleting it immediately." >&2
    fi
    /usr/bin/security delete-keychain "$validated_keychain"
  fi
  if ! rmdir "$validated_work_dir"; then
    echo "The signing work directory contains unexpected leftover files." >&2
    exit 1
  fi
  exit 0
fi

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${APPLE_DEVELOPER_ID_P12_BASE64:?APPLE_DEVELOPER_ID_P12_BASE64 is required}"
: "${APPLE_DEVELOPER_ID_P12_PASSWORD:?APPLE_DEVELOPER_ID_P12_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "APPLE_TEAM_ID must be a 10-character Apple team identifier." >&2
  exit 1
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

canonical_contained_file() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

root = os.path.realpath(os.path.abspath(sys.argv[1]))
supplied = os.path.abspath(sys.argv[2])
if "\n" in supplied or "\r" in supplied:
    raise SystemExit("File path must not contain newlines")
if os.path.islink(supplied):
    raise SystemExit(f"Refusing symlink file {supplied!r}")
cursor = supplied
components = []
while os.path.realpath(cursor) != root:
    parent = os.path.dirname(cursor)
    if parent == cursor:
        raise SystemExit(f"Path escapes RUNNER_TEMP: {supplied!r}")
    components.append(os.path.basename(cursor))
    cursor = parent
current = cursor
for component in reversed(components):
    current = os.path.join(current, component)
    if os.path.islink(current):
        raise SystemExit(f"Refusing symlink path component {current!r}")
path = os.path.realpath(supplied)
try:
    if os.path.commonpath((root, path)) != root:
        raise SystemExit(f"Path escapes RUNNER_TEMP: {supplied!r}")
except ValueError:
    raise SystemExit(f"Path escapes RUNNER_TEMP: {supplied!r}")
try:
    mode = os.stat(path, follow_symlinks=False).st_mode
except OSError as error:
    raise SystemExit(f"Unable to inspect file {path!r}: {error}")
if not stat.S_ISREG(mode):
    raise SystemExit(f"Expected a regular file, got {path!r}")
print(path)
PY
}

runner_temp="$(canonical_directory "$RUNNER_TEMP")"
github_env="$(canonical_contained_file "$runner_temp" "$GITHUB_ENV")"
signing_work_dir="$(/usr/bin/mktemp -d "${runner_temp}/phonoflow-signing.XXXXXX")"
signing_work_dir="$(canonical_directory "$signing_work_dir")"
chmod 700 "$signing_work_dir"
certificate_path="${signing_work_dir}/developer-id.p12"
keychain_path="${signing_work_dir}/signing.keychain-db"
keychain_password="$(/usr/bin/openssl rand -hex 32)"
if [[ ! "$keychain_password" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Unable to generate a secure temporary keychain password." >&2
  exit 1
fi
echo "::add-mask::${keychain_password}"

keychain_created=0
keychain_locked=0
completed=0
cleanup_signing_import() {
  status=$?
  trap - EXIT
  set +e
  cleanup_status=0

  if [[ -f "$certificate_path" || -L "$certificate_path" ]]; then
    rm -f -- "$certificate_path" || cleanup_status=1
  fi

  if [[ "$keychain_created" -eq 1 && "$keychain_locked" -ne 1 ]]; then
    if /usr/bin/security lock-keychain "$keychain_path" >/dev/null 2>&1; then
      keychain_locked=1
    else
      cleanup_status=1
      completed=0
    fi
  fi

  if [[ "$completed" -ne 1 ]]; then
    if [[ "$keychain_created" -eq 1 ]]; then
      /usr/bin/security delete-keychain "$keychain_path" >/dev/null 2>&1 \
        || cleanup_status=1
    fi
    if [[ -d "$signing_work_dir" && ! -L "$signing_work_dir" ]]; then
      rmdir "$signing_work_dir" >/dev/null 2>&1 || cleanup_status=1
    fi
  fi

  if [[ "$cleanup_status" -ne 0 ]]; then
    if [[ -e "$signing_work_dir" || -L "$signing_work_dir" ]]; then
      {
        printf '%s\n' "SIGNING_WORK_DIR=${signing_work_dir}"
        printf '%s\n' "SIGNING_KEYCHAIN=${keychain_path}"
      } >> "$github_env" || true
    fi
    echo "Failed to securely lock or clean up the temporary signing keychain." >&2
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup_signing_import EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" \
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
    raise SystemExit("decoded certificate is empty")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(path, flags, 0o600)
with os.fdopen(descriptor, "wb") as destination:
    destination.write(decoded)
' "$certificate_path"; then
  echo "APPLE_DEVELOPER_ID_P12_BASE64 is not valid base64." >&2
  exit 1
fi
if [[ ! -s "$certificate_path" || -L "$certificate_path" ]]; then
  echo "The decoded Developer ID certificate is empty or unsafe." >&2
  exit 1
fi

/usr/bin/security create-keychain -p "$keychain_password" "$keychain_path"
keychain_created=1
if [[ ! -f "$keychain_path" || -L "$keychain_path" ]]; then
  echo "security did not create a regular keychain file." >&2
  exit 1
fi
chmod 600 "$keychain_path"
/usr/bin/security set-keychain-settings -lut 7200 "$keychain_path"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain_path"
/usr/bin/security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
  -f pkcs12 \
  -x \
  -T /usr/bin/codesign
unset APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD
/usr/bin/security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"

identity_lines="$(
  /usr/bin/security find-identity -v -p codesigning "$keychain_path" \
    | grep -F "Developer ID Application:" \
    | grep -F "(${APPLE_TEAM_ID})" || true
)"
identity_count="$(printf '%s\n' "$identity_lines" | grep -c . || true)"
if [[ "$identity_count" -ne 1 ]]; then
  echo "Expected exactly one valid Developer ID Application identity for team ${APPLE_TEAM_ID}." >&2
  /usr/bin/security find-identity -v -p codesigning "$keychain_path" >&2
  exit 1
fi

signing_identity="$(printf '%s\n' "$identity_lines" | awk '{print $2}')"
if [[ ! "$signing_identity" =~ ^[0-9A-F]{40}$ ]]; then
  echo "Unable to determine the Developer ID signing identity hash." >&2
  exit 1
fi

rm -f -- "$certificate_path"
/usr/bin/security lock-keychain "$keychain_path"
keychain_locked=1

{
  echo "SIGNING_WORK_DIR=${signing_work_dir}"
  echo "SIGNING_KEYCHAIN=${keychain_path}"
  echo "SIGNING_IDENTITY=${signing_identity}"
  echo "SIGNING_KEYCHAIN_PASSWORD=${keychain_password}"
} >> "$github_env"
completed=1

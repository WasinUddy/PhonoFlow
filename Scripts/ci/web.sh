#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 check | acceptance <chromium|webkit>" >&2
}

repo_root="$(git rev-parse --show-toplevel)"
mode="${1:-}"
browser="${2:-}"

if [[ "$mode" != "check" && "$mode" != "acceptance" ]]; then
  usage
  exit 2
fi

if [[ "$mode" == "acceptance" && "$browser" != "chromium" && "$browser" != "webkit" ]]; then
  usage
  exit 2
fi

if [[ "$mode" == "check" ]]; then
  python3 "$repo_root/Scripts/ci/test_acceptance_ci.py"
fi

find_manifests() {
  git -C "$repo_root" ls-files -- '*package.json' \
    | grep -Ev '(^|/)(node_modules|DerivedData|\.build)/' || true
}

has_script() {
  local script_name="$1"
  node -e '
    const pkg = require("./package.json");
    process.exit(pkg.scripts && pkg.scripts[process.argv[1]] ? 0 : 1);
  ' "$script_name"
}

install_dependencies() {
  if [[ ! -f package-lock.json && ! -f npm-shrinkwrap.json ]]; then
    echo "A committed package-lock.json or npm-shrinkwrap.json is required in $PWD." >&2
    exit 1
  fi

  npm ci --ignore-scripts --no-audit --no-fund
}

mapfile_compat_file="$(mktemp "${TMPDIR:-/tmp}/phonoflow-web-manifests.XXXXXX")"
trap 'rm -f "$mapfile_compat_file"' EXIT
find_manifests > "$mapfile_compat_file"

if [[ ! -s "$mapfile_compat_file" ]]; then
  echo "No tracked package.json was found. The bundled WebUI test project is required." >&2
  exit 1
fi

if [[ "$mode" == "check" ]]; then
  while IFS= read -r manifest; do
    package_dir="$repo_root/$(dirname "$manifest")"
    echo "::group::Web checks in $package_dir"
    pushd "$package_dir" >/dev/null
    install_dependencies

    ran_check=0
    for script_name in format:check lint typecheck; do
      if has_script "$script_name"; then
        npm run "$script_name"
        ran_check=1
      fi
    done
    if ! has_script test:coverage; then
      echo "A test:coverage script with enforced thresholds is required in $package_dir." >&2
      exit 1
    fi
    npm run test:coverage
    ran_check=1
    if ! has_script coverage:gate; then
      echo "A coverage:gate script is required in $package_dir." >&2
      exit 1
    fi
    if [[ -n "${COVERAGE_BASE_SHA:-}" ]]; then
      npm run coverage:gate -- \
        --base-sha "$COVERAGE_BASE_SHA" \
        --aggregate-minimum 90 \
        --changed-minimum 90
    elif [[ "${WEBUI_REQUIRE_CHANGED_COVERAGE:-0}" == "1" ]]; then
      echo "WEBUI_REQUIRE_CHANGED_COVERAGE=1 requires COVERAGE_BASE_SHA." >&2
      exit 1
    else
      echo "COVERAGE_BASE_SHA is unavailable; the enforced 90% aggregate WebUI gate remains active."
    fi
    if has_script build; then
      npm run build
      ran_check=1
    fi

    if [[ "$ran_check" -ne 1 ]]; then
      echo "At least one validation, test, or build script must be defined." >&2
      exit 1
    fi

    popd >/dev/null
    echo "::endgroup::"
  done < "$mapfile_compat_file"
  exit 0
fi

acceptance_dir=""
while IFS= read -r manifest; do
  candidate_dir="$repo_root/$(dirname "$manifest")"
  if (
    cd "$candidate_dir"
    has_script test:acceptance \
      || node -e '
        const pkg = require("./package.json");
        const deps = {...pkg.dependencies, ...pkg.devDependencies};
        process.exit(deps["@playwright/test"] || deps.playwright ? 0 : 1);
      '
  ); then
    acceptance_dir="$candidate_dir"
    break
  fi
done < "$mapfile_compat_file"

if [[ -z "$acceptance_dir" ]]; then
  echo "No WebUI package with Playwright or a test:acceptance script was found." >&2
  exit 1
fi

cd "$acceptance_dir"
if [[ "${PHONOFLOW_WEBUI_PREPARED:-0}" != "1" ]]; then
  install_dependencies
elif [[ ! -d node_modules ]]; then
  echo "PHONOFLOW_WEBUI_PREPARED=1 requires an existing locked install." >&2
  exit 1
fi

if [[ ! -x node_modules/.bin/playwright ]]; then
  echo "Playwright must be a locked development dependency of the WebUI package." >&2
  exit 1
fi

if [[ "${PHONOFLOW_WEBUI_PREPARED:-0}" != "1" ]]; then
  node_modules/.bin/playwright install "$browser"
fi

if has_script test:acceptance; then
  npm run test:acceptance -- --project="$browser"
else
  node_modules/.bin/playwright test --project="$browser"
fi

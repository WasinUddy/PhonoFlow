#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

mode="${1:-}"
if [[ "$mode" != "ci" && "$mode" != "acceptance" && "$mode" != "focusrite" && "$mode" != "release" ]]; then
  echo "Usage: $0 ci | acceptance | focusrite | release" >&2
  exit 2
fi

repo_root="$(/usr/bin/git rev-parse --show-toplevel)"
cd "$repo_root"

project="PhonoFlow.xcodeproj"
scheme_name="PhonoFlow"
scheme="${project}/xcshareddata/xcschemes/${scheme_name}.xcscheme"
package_resolved="${project}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
test_plans=(
  "PhonoFlow-CI.xctestplan"
  "PhonoFlow-Acceptance.xctestplan"
  "PhonoFlow-Focusrite.xctestplan"
)

require_tracked_file() {
  local path="$1"
  if [[ ! -f "$path" || -L "$path" ]] \
    || ! /usr/bin/git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    echo "A committed regular file is required at ${path}." >&2
    exit 1
  fi
}

require_tracked_file "$scheme"
require_tracked_file "$package_resolved"
for test_plan in "${test_plans[@]}"; do
  require_tracked_file "$test_plan"
  # macOS 26's `plutil -lint` only accepts legacy plist syntax, while Xcode
  # stores test plans as JSON property lists. Converting to a discarded plist
  # validates both the JSON and property-list structure across runner images.
  if ! /usr/bin/plutil -convert xml1 -o /dev/null -- "$test_plan" >/dev/null; then
    echo "${test_plan} is not a valid test plan." >&2
    exit 1
  fi
done

/usr/bin/python3 - "$scheme" "${test_plans[@]}" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"Invalid shared scheme/test-plan contract: {message}")


scheme_path = Path(sys.argv[1])
plan_paths = [Path(value) for value in sys.argv[2:]]

try:
    scheme = ET.parse(scheme_path).getroot()
except (ET.ParseError, OSError) as error:
    fail(f"{scheme_path} cannot be parsed: {error}")

if scheme.tag != "Scheme":
    fail(f"{scheme_path} must have a Scheme root")
if scheme.attrib != {"LastUpgradeVersion": "2660", "version": "1.7"}:
    fail(f"{scheme_path} has unexpected Scheme attributes")
expected_action_order = [
    "BuildAction",
    "TestAction",
    "LaunchAction",
    "ProfileAction",
    "AnalyzeAction",
    "ArchiveAction",
]
if [child.tag for child in scheme] != expected_action_order:
    fail(f"{scheme_path} has unexpected or reordered actions")
for forbidden in ("PreActions", "PostActions", "ExecutionAction", "ActionContent"):
    if scheme.findall(f".//{forbidden}"):
        fail(f"{scheme_path} must not contain executable {forbidden}")

expected_buildables = [
    (
        "primary",
        "081D97BA2F74DC85003C5872",
        "PhonoFlow.app",
        "PhonoFlow",
        "container:PhonoFlow.xcodeproj",
        ("YES", "YES", "YES", "YES", "YES"),
    ),
    (
        "primary",
        "E10000000000000000000002",
        "PhonoFlowTests.xctest",
        "PhonoFlowTests",
        "container:PhonoFlow.xcodeproj",
        ("YES", "NO", "NO", "NO", "NO"),
    ),
    (
        "primary",
        "E10000000000000000000001",
        "PhonoFlowUITests.xctest",
        "PhonoFlowUITests",
        "container:PhonoFlow.xcodeproj",
        ("YES", "NO", "NO", "NO", "NO"),
    ),
]
actual_buildables = []
build_action = scheme.find("./BuildAction")
if build_action is None or build_action.attrib != {
    "parallelizeBuildables": "YES",
    "buildImplicitDependencies": "YES",
    "buildArchitectures": "Automatic",
}:
    fail("the BuildAction has unexpected attributes")
if [child.tag for child in build_action] != ["BuildActionEntries"]:
    fail("the BuildAction must contain exactly one BuildActionEntries element")
build_entries = build_action.find("./BuildActionEntries")
if build_entries is None or build_entries.attrib:
    fail("BuildActionEntries has unexpected attributes")
if any(child.tag != "BuildActionEntry" for child in build_entries):
    fail("BuildActionEntries contains an unexpected element")

for entry in build_entries:
    if [child.tag for child in entry] != ["BuildableReference"]:
        fail("every BuildActionEntry must contain exactly one BuildableReference")
    expected_entry_attributes = {
        "buildForTesting",
        "buildForRunning",
        "buildForProfiling",
        "buildForArchiving",
        "buildForAnalyzing",
    }
    if set(entry.attrib) != expected_entry_attributes:
        fail("a BuildActionEntry has unexpected attributes")
    reference = entry.find("./BuildableReference")
    if (
        reference is None
        or set(reference.attrib)
        != {
            "BuildableIdentifier",
            "BlueprintIdentifier",
            "BuildableName",
            "BlueprintName",
            "ReferencedContainer",
        }
        or list(reference)
    ):
        fail("a BuildActionEntry has an unexpected BuildableReference contract")
    actual_buildables.append(
        (
            reference.get("BuildableIdentifier"),
            reference.get("BlueprintIdentifier"),
            reference.get("BuildableName"),
            reference.get("BlueprintName"),
            reference.get("ReferencedContainer"),
            tuple(
                entry.get(attribute)
                for attribute in (
                    "buildForTesting",
                    "buildForRunning",
                    "buildForProfiling",
                    "buildForArchiving",
                    "buildForAnalyzing",
                )
            ),
        )
    )
if actual_buildables != expected_buildables:
    fail("PhonoFlow.xcscheme has unexpected build targets or build actions")

test_action = scheme.find("./TestAction")
if test_action is None or test_action.attrib != {
    "buildConfiguration": "Debug",
    "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
    "selectedLauncherIdentifier": "Xcode.DebuggerFoundation.Launcher.LLDB",
    "shouldUseLaunchSchemeArgsEnv": "YES",
    "shouldAutocreateTestPlan": "NO",
}:
    fail("the TestAction must use the exact committed-plan contract")
if [child.tag for child in test_action] != ["TestPlans"]:
    fail("the TestAction must contain exactly one TestPlans element")
test_plans_element = test_action.find("./TestPlans")
if test_plans_element is None or test_plans_element.attrib:
    fail("TestPlans has unexpected attributes")
if any(
    child.tag != "TestPlanReference"
    or set(child.attrib) != {"reference", "default"}
    or list(child)
    for child in test_plans_element
):
    fail("TestPlans contains an unexpected element")

expected_plan_references = [
    ("container:PhonoFlow-CI.xctestplan", "YES"),
    ("container:PhonoFlow-Acceptance.xctestplan", "NO"),
    ("container:PhonoFlow-Focusrite.xctestplan", "NO"),
]
actual_plan_references = [
    (reference.get("reference"), reference.get("default"))
    for reference in test_action.findall("./TestPlans/TestPlanReference")
]
if actual_plan_references != expected_plan_references:
    fail("PhonoFlow.xcscheme must reference exactly CI, acceptance, and Focusrite plans")

archive_action = scheme.find("./ArchiveAction")
if (
    archive_action is None
    or archive_action.attrib
    != {
        "buildConfiguration": "Release",
        "revealArchiveInOrganizer": "YES",
    }
    or list(archive_action)
):
    fail("the shared scheme must use the exact Release archive contract")

analyze_action = scheme.find("./AnalyzeAction")
if (
    analyze_action is None
    or analyze_action.attrib != {"buildConfiguration": "Debug"}
    or list(analyze_action)
):
    fail("the shared scheme has an unexpected AnalyzeAction")

expected_app_reference = {
    "BuildableIdentifier": "primary",
    "BlueprintIdentifier": "081D97BA2F74DC85003C5872",
    "BuildableName": "PhonoFlow.app",
    "BlueprintName": "PhonoFlow",
    "ReferencedContainer": "container:PhonoFlow.xcodeproj",
}
expected_runnable_actions = {
    "LaunchAction": {
        "buildConfiguration": "Debug",
        "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
        "selectedLauncherIdentifier": "Xcode.DebuggerFoundation.Launcher.LLDB",
        "launchStyle": "0",
        "useCustomWorkingDirectory": "NO",
        "ignoresPersistentStateOnLaunch": "NO",
        "debugDocumentVersioning": "YES",
        "debugServiceExtension": "internal",
        "allowLocationSimulation": "YES",
    },
    "ProfileAction": {
        "buildConfiguration": "Release",
        "shouldUseLaunchSchemeArgsEnv": "YES",
        "savedToolIdentifier": "",
        "useCustomWorkingDirectory": "NO",
        "debugDocumentVersioning": "YES",
    },
}
for action_name, expected_attributes in expected_runnable_actions.items():
    action = scheme.find(f"./{action_name}")
    if action is None or action.attrib != expected_attributes:
        fail(f"the shared scheme has an unexpected {action_name}")
    if [child.tag for child in action] != ["BuildableProductRunnable"]:
        fail(f"{action_name} must contain exactly one BuildableProductRunnable")
    runnable = action.find("./BuildableProductRunnable")
    if (
        runnable is None
        or runnable.attrib != {"runnableDebuggingMode": "0"}
        or [child.tag for child in runnable] != ["BuildableReference"]
    ):
        fail(f"{action_name} has an unexpected runnable contract")
    reference = runnable.find("./BuildableReference")
    if reference is None or reference.attrib != expected_app_reference or list(reference):
        fail(f"{action_name} references an unexpected runnable")

expected_plans = {
    "PhonoFlow-CI.xctestplan": {
        "configuration": "CI",
        "coverage": True,
        "target": (
            "E10000000000000000000002",
            "PhonoFlowTests",
            True,
        ),
        "selectedTests": None,
    },
    "PhonoFlow-Acceptance.xctestplan": {
        "configuration": "Fake Scarlett",
        "coverage": False,
        "target": (
            "E10000000000000000000001",
            "PhonoFlowUITests",
            False,
        ),
        "selectedTests": None,
    },
    "PhonoFlow-Focusrite.xctestplan": {
        "configuration": "Protected Focusrite Hardware",
        "coverage": False,
        "target": (
            "E10000000000000000000002",
            "PhonoFlowTests",
            False,
        ),
        "selectedTests": [
            "FocusriteHardwareSoakTests/testFocusriteCaptureSoak()"
        ],
    },
}
expected_expansion_target = (
    "container:PhonoFlow.xcodeproj",
    "081D97BA2F74DC85003C5872",
    "PhonoFlow",
)

if {path.name for path in plan_paths} != set(expected_plans):
    fail("preflight must validate exactly the three committed test plans")

for path in plan_paths:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        fail(f"{path} cannot be parsed: {error}")

    expected = expected_plans[path.name]
    if set(plan) != {"configurations", "defaultOptions", "testTargets", "version"}:
        fail(f"{path} has unexpected top-level fields")
    if plan.get("version") != 1:
        fail(f"{path} must use test-plan version 1")

    configurations = plan.get("configurations", [])
    configuration_names = [
        configuration.get("name") for configuration in configurations
    ]
    if configuration_names != [expected["configuration"]]:
        fail(f"{path} has an unexpected configuration")
    configuration = configurations[0]
    if (
        set(configuration) != {"id", "name", "options"}
        or not isinstance(configuration.get("id"), str)
        or not configuration["id"]
        or configuration.get("options") != {}
    ):
        fail(f"{path} has an unexpected configuration contract")

    options = plan.get("defaultOptions", {})
    if set(options) != {"codeCoverage", "targetForVariableExpansion"}:
        fail(f"{path} has unexpected default options")
    if options.get("codeCoverage") is not expected["coverage"]:
        fail(f"{path} has an unexpected code-coverage setting")
    expansion = options.get("targetForVariableExpansion", {})
    actual_expansion_target = (
        expansion.get("containerPath"),
        expansion.get("identifier"),
        expansion.get("name"),
    )
    if actual_expansion_target != expected_expansion_target:
        fail(f"{path} expands variables against an unexpected target")

    targets = plan.get("testTargets", [])
    if len(targets) != 1:
        fail(f"{path} must contain exactly one test target")
    target_entry = targets[0]
    target = target_entry.get("target", {})
    actual_target = (
        target.get("identifier"),
        target.get("name"),
        target_entry.get("parallelizable"),
    )
    if actual_target != expected["target"]:
        fail(f"{path} contains an unexpected test target")
    if target != {
        "containerPath": "container:PhonoFlow.xcodeproj",
        "identifier": expected["target"][0],
        "name": expected["target"][1],
    }:
        fail(f"{path} has an unexpected target contract")
    expected_target_fields = {"parallelizable", "skippedTests", "target"}
    if expected["selectedTests"] is not None:
        expected_target_fields.add("selectedTests")
    if set(target_entry) != expected_target_fields:
        fail(f"{path} has unexpected test-target fields")
    if target_entry.get("skippedTests") != []:
        fail(f"{path} must not skip tests")
    if target_entry.get("selectedTests") != expected["selectedTests"]:
        if expected["selectedTests"] is not None or "selectedTests" in target_entry:
            fail(f"{path} has an unexpected selected-tests list")
PY

tracked_user_data="$(/usr/bin/git ls-files -- '*xcuserdata*' '*.xcuserstate' '*/*.xcuserstate')"
if [[ -n "$tracked_user_data" ]]; then
  echo "User-specific Xcode state must not be tracked:" >&2
  echo "$tracked_user_data" >&2
  exit 1
fi

if [[ -n "${EXPECTED_ARCHITECTURE:-}" && "$(/usr/bin/uname -m)" != "$EXPECTED_ARCHITECTURE" ]]; then
  echo "Runner architecture is $(/usr/bin/uname -m); expected $EXPECTED_ARCHITECTURE." >&2
  exit 1
fi

case "$mode" in
  ci | acceptance | focusrite)
    ;;
  release)
    : "${RUNNER_TEMP:?RUNNER_TEMP is required for release preflight}"
    : "${GITHUB_ENV:?GITHUB_ENV is required for release preflight}"

    validated_release_paths="$(
      /usr/bin/python3 - "$RUNNER_TEMP" "$GITHUB_ENV" <<'PY'
import os
import stat
import sys

runner_supplied = os.path.abspath(sys.argv[1])
output_supplied = os.path.abspath(sys.argv[2])
if any("\n" in value or "\r" in value for value in sys.argv[1:]):
    raise SystemExit("Release preflight paths must not contain newlines")
if os.path.islink(runner_supplied):
    raise SystemExit("Refusing symlinked RUNNER_TEMP")
runner = os.path.realpath(runner_supplied)
runner_mode = os.stat(runner, follow_symlinks=False).st_mode
if not stat.S_ISDIR(runner_mode):
    raise SystemExit("RUNNER_TEMP must be a directory")
if os.path.islink(output_supplied):
    raise SystemExit("Refusing symlinked GITHUB_ENV")
output = os.path.realpath(output_supplied)
try:
    if os.path.commonpath((runner, output)) != runner or output == runner:
        raise SystemExit("GITHUB_ENV must be contained by RUNNER_TEMP")
except ValueError:
    raise SystemExit("GITHUB_ENV must be contained by RUNNER_TEMP")
output_mode = os.stat(output, follow_symlinks=False).st_mode
if not stat.S_ISREG(output_mode):
    raise SystemExit("GITHUB_ENV must be a regular file")
print(runner)
print(output)
PY
    )"
    runner_temp="${validated_release_paths%%$'\n'*}"
    github_env="${validated_release_paths#*$'\n'}"
    preflight_work_dir="$(
      /usr/bin/mktemp -d "${runner_temp}/phonoflow-preflight.XXXXXX"
    )"
    source_packages_path="$(
      /usr/bin/mktemp -d "${runner_temp}/phonoflow-packages.XXXXXX"
    )"
    preflight_work_identity="$(/usr/bin/stat -f '%d:%i' "$preflight_work_dir")"
    source_packages_identity="$(/usr/bin/stat -f '%d:%i' "$source_packages_path")"
    preflight_succeeded=0

    cleanup_release_preflight() {
      status=$?
      trap - EXIT
      set +e
      cleanup_status=0

      if [[ "$(/usr/bin/stat -f '%d:%i' "$preflight_work_dir" 2>/dev/null)" \
        != "$preflight_work_identity" ]]; then
        cleanup_status=1
      elif [[ -d "$preflight_work_dir" && ! -L "$preflight_work_dir" ]]; then
        /bin/rm -rf -- "$preflight_work_dir" || cleanup_status=1
      fi

      if [[ "$preflight_succeeded" -ne 1 ]]; then
        if [[ "$(/usr/bin/stat -f '%d:%i' "$source_packages_path" 2>/dev/null)" \
          != "$source_packages_identity" ]]; then
          cleanup_status=1
        elif [[ -d "$source_packages_path" && ! -L "$source_packages_path" ]]; then
          /bin/rm -rf -- "$source_packages_path" || cleanup_status=1
        fi
      fi

      if [[ "$cleanup_status" -ne 0 ]]; then
        echo "Release preflight could not safely remove its temporary files." >&2
        if [[ "$status" -eq 0 ]]; then
          status=1
        fi
      fi
      exit "$status"
    }
    trap cleanup_release_preflight EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=all -- "$package_resolved")" ]]; then
      echo "${package_resolved} must be clean before locked package resolution." >&2
      exit 1
    fi

    /usr/bin/xcodebuild \
      -resolvePackageDependencies \
      -project "$project" \
      -scheme "$scheme_name" \
      -clonedSourcePackagesDirPath "$source_packages_path" \
      -disableAutomaticPackageResolution \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackageUpdates

    if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=all -- "$package_resolved")" ]]; then
      echo "Locked package resolution changed ${package_resolved}." >&2
      exit 1
    fi

    build_settings_path="${preflight_work_dir}/release-build-settings.json"
    /usr/bin/xcodebuild \
      -project "$project" \
      -scheme "$scheme_name" \
      -configuration Release \
      -clonedSourcePackagesDirPath "$source_packages_path" \
      -disableAutomaticPackageResolution \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackageUpdates \
      -showBuildSettings \
      -json \
      CODE_SIGNING_ALLOWED=NO \
      > "$build_settings_path"

    /usr/bin/python3 - "$build_settings_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    entries = json.load(source)

targets = [entry for entry in entries if entry.get("target") == "PhonoFlow"]
if len(targets) != 1:
    raise SystemExit("Release settings must contain exactly one PhonoFlow target")

settings = targets[0].get("buildSettings", {})
expected = {
    "CONFIGURATION": "Release",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.wasinuddy.PhonoFlow",
    "WRAPPER_EXTENSION": "app",
}
failures = [
    f"{key}={settings.get(key)!r} (expected {value!r})"
    for key, value in expected.items()
    if settings.get(key) != value
]
if failures:
    raise SystemExit("Invalid PhonoFlow Release settings: " + ", ".join(failures))
PY
    [[ "$(/usr/bin/stat -f '%d:%i' "$source_packages_path")" \
      == "$source_packages_identity" ]] \
      || {
        echo "The locked package directory changed identity during preflight." >&2
        exit 1
      }
    printf '%s\n' "RELEASE_SOURCE_PACKAGES=${source_packages_path}" >> "$github_env"
    preflight_succeeded=1
    ;;
esac

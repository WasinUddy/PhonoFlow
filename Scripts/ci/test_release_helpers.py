#!/usr/bin/env python3

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Dict, Optional


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPOSITORY_ROOT / "Scripts" / "ci"


def run_script(
    script: Path,
    *arguments: str,
    cwd: Optional[Path] = None,
    environment: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if environment:
        env.update(environment)
    return subprocess.run(
        ["/bin/bash", str(script), *arguments],
        cwd=cwd,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


class ReleaseHelperTests(unittest.TestCase):
    def make_preflight_repository(self, root: Path) -> Path:
        script = root / "Scripts" / "ci" / "preflight.sh"
        scheme = (
            root
            / "PhonoFlow.xcodeproj"
            / "xcshareddata"
            / "xcschemes"
            / "PhonoFlow.xcscheme"
        )
        package_resolved = (
            root
            / "PhonoFlow.xcodeproj"
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved"
        )
        script.parent.mkdir(parents=True)
        scheme.parent.mkdir(parents=True)
        package_resolved.parent.mkdir(parents=True)
        shutil.copy2(SCRIPTS / "preflight.sh", script)
        shutil.copy2(
            REPOSITORY_ROOT
            / "PhonoFlow.xcodeproj"
            / "xcshareddata"
            / "xcschemes"
            / "PhonoFlow.xcscheme",
            scheme,
        )
        shutil.copy2(
            REPOSITORY_ROOT
            / "PhonoFlow.xcodeproj"
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved",
            package_resolved,
        )
        for name in (
            "PhonoFlow-CI.xctestplan",
            "PhonoFlow-Acceptance.xctestplan",
            "PhonoFlow-Focusrite.xctestplan",
        ):
            shutil.copy2(REPOSITORY_ROOT / name, root / name)
        subprocess.run(
            ["/usr/bin/git", "init", "-q"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["/usr/bin/git", "add", "."],
            cwd=root,
            check=True,
        )
        return script

    def test_preflight_accepts_exact_committed_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = self.make_preflight_repository(root)
            result = run_script(script, "ci", cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_preflight_rejects_invalid_or_renamed_plan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = self.make_preflight_repository(root)
            plan = root / "PhonoFlow-CI.xctestplan"
            plan.write_text("{invalid", encoding="utf-8")
            invalid = run_script(script, "ci", cwd=root)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("not a valid test plan", invalid.stderr)

            plan.unlink()
            renamed = root / "backup-PhonoFlow-CI.xctestplan"
            renamed.write_text("{}", encoding="utf-8")
            subprocess.run(
                ["/usr/bin/git", "add", "-A"],
                cwd=root,
                check=True,
            )
            missing = run_script(script, "ci", cwd=root)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn(
                "A committed regular file is required at PhonoFlow-CI.xctestplan",
                missing.stderr,
            )

    def test_release_preflight_rejects_symlinked_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = self.make_preflight_repository(root)
            runner_temp = root / "runner"
            runner_temp.mkdir()
            real_output = runner_temp / "environment"
            real_output.touch()
            linked_output = runner_temp / "environment-link"
            linked_output.symlink_to(real_output)
            result = run_script(
                script,
                "release",
                cwd=root,
                environment={
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_ENV": str(linked_output),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing symlinked GITHUB_ENV", result.stderr)

    def test_invalid_certificate_is_removed_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory)
            github_env = runner_temp / "environment"
            github_env.touch()
            result = run_script(
                SCRIPTS / "import-signing-certificate.sh",
                environment={
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_ENV": str(github_env),
                    "APPLE_DEVELOPER_ID_P12_BASE64": "not-base64!",
                    "APPLE_DEVELOPER_ID_P12_PASSWORD": "password",
                    "APPLE_TEAM_ID": "ABCDEFGHIJ",
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(list(runner_temp.glob("phonoflow-signing.*")))

    def test_cleanup_rejects_symlinked_signing_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory)
            target = runner_temp / "target"
            target.mkdir()
            work = runner_temp / "phonoflow-signing.ABC123"
            work.symlink_to(target, target_is_directory=True)
            result = run_script(
                SCRIPTS / "import-signing-certificate.sh",
                "--cleanup",
                environment={
                    "RUNNER_TEMP": str(runner_temp),
                    "SIGNING_WORK_DIR": str(work),
                    "SIGNING_KEYCHAIN": str(work / "signing.keychain-db"),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing symlinked signing cleanup paths", result.stderr)

    def test_notary_rejects_symlinked_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory)
            github_output = runner_temp / "output"
            github_output.touch()
            work = runner_temp / "phonoflow-release.ABC123"
            release = work / "release-assets"
            dsym = (
                work
                / "PhonoFlow.xcarchive"
                / "dSYMs"
                / "PhonoFlow.app.dSYM"
            )
            release.mkdir(parents=True)
            dsym.mkdir(parents=True)
            target = release / "target.dmg"
            target.touch()
            dmg = release / "PhonoFlow-1.2.3-macOS-universal.dmg"
            dmg.symlink_to(target)
            result = run_script(
                SCRIPTS / "notarize-release.sh",
                str(dmg),
                str(dsym),
                environment={
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(github_output),
                    "GITHUB_RUN_NUMBER": "1",
                    "VERSION": "1.2.3",
                    "APPLE_TEAM_ID": "ABCDEFGHIJ",
                    "RELEASE_SIGNING_IDENTITY": "A" * 40,
                    "APPLE_NOTARY_KEY_P8_BASE64": "a2V5",
                    "APPLE_NOTARY_KEY_ID": "ABCDEFGHIJ",
                    "APPLE_NOTARY_ISSUER_ID": (
                        "12345678-1234-4123-8123-123456789012"
                    ),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing symlink path", result.stderr)

    def test_invalid_notary_key_is_removed_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory)
            github_output = runner_temp / "output"
            github_output.touch()
            work = runner_temp / "phonoflow-release.ABC123"
            release = work / "release-assets"
            dsym = (
                work
                / "PhonoFlow.xcarchive"
                / "dSYMs"
                / "PhonoFlow.app.dSYM"
            )
            release.mkdir(parents=True)
            dsym.mkdir(parents=True)
            dmg = release / "PhonoFlow-1.2.3-macOS-universal.dmg"
            dmg.touch()
            result = run_script(
                SCRIPTS / "notarize-release.sh",
                str(dmg),
                str(dsym),
                environment={
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(github_output),
                    "GITHUB_RUN_NUMBER": "1",
                    "VERSION": "1.2.3",
                    "APPLE_TEAM_ID": "ABCDEFGHIJ",
                    "RELEASE_SIGNING_IDENTITY": "A" * 40,
                    "APPLE_NOTARY_KEY_P8_BASE64": "not-base64!",
                    "APPLE_NOTARY_KEY_ID": "ABCDEFGHIJ",
                    "APPLE_NOTARY_ISSUER_ID": (
                        "12345678-1234-4123-8123-123456789012"
                    ),
                },
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(list(runner_temp.glob("phonoflow-notary.*")))

    def test_security_controls_remain_enabled(self) -> None:
        import_script = (SCRIPTS / "import-signing-certificate.sh").read_text()
        artifact_script = (SCRIPTS / "release-artifacts.sh").read_text()
        notary_script = (SCRIPTS / "notarize-release.sh").read_text()
        preflight_script = (SCRIPTS / "preflight.sh").read_text()

        self.assertIn("os.O_EXCL", import_script)
        self.assertIn("os.O_EXCL", notary_script)
        self.assertNotIn("OTHER_CODE_SIGN_FLAGS=", artifact_script)
        self.assertIn('--architecture "$architecture"', artifact_script)
        self.assertIn('--architecture "$architecture"', notary_script)
        self.assertIn("-mode 755", artifact_script)
        self.assertIn("-uid 99", artifact_script)
        self.assertIn("-gid 99", artifact_script)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", preflight_script)
        self.assertIn("-disableAutomaticPackageResolution", preflight_script)
        self.assertIn("-skipPackageUpdates", preflight_script)


if __name__ == "__main__":
    unittest.main()

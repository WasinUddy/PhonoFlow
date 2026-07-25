# PhonoFlow CI/CD operations

All workflows use Xcode 26.4 from
`/Applications/Xcode_26.4.app/Contents/Developer`. Action references are pinned to
immutable commit SHAs. Dependabot proposes action, root Xcode Swift package,
`PhonoFlowCore` Swift package, and WebUI lockfile updates.

## Required repository files

- Commit `PhonoFlow.xcodeproj/xcshareddata/xcschemes/PhonoFlow.xcscheme`.
- Commit the `PhonoFlow-CI`, `PhonoFlow-Acceptance`, and `PhonoFlow-Focusrite`
  test plans and include their test targets in the shared scheme.
- Commit every `Package.resolved` and `WebUI/package-lock.json`. Builds reject
  unlocked dependency resolution.
- Do not commit `xcuserdata`, `.xcuserstate`, build output, Playwright reports, or
  acceptance state directories.

SwiftPM independently enforces 90% line coverage under `PhonoFlowCore/Sources`.
The `PhonoFlow-CI` result bundle enforces 80% non-view application coverage and
90% changed executable-line coverage for application sources.

The acceptance-only application bootstrap uses this fixed environment contract:

```text
PHONOFLOW_ACCEPTANCE=1
PHONOFLOW_AUDIO_BACKEND=fake
PHONOFLOW_REMOTE_BIND_HOST=127.0.0.1
PHONOFLOW_REMOTE_PORT=17866
PHONOFLOW_PAIRING_CODE=123456
PHONOFLOW_STATE_DIR=<runner temporary directory>
PHONOFLOW_DISABLE_BONJOUR=1
```

The fake backend exposes four input channels. The browser job launches the built
application, waits for `GET /` to return the PhonoFlow Remote page, verifies that
the process owns only the expected loopback listener, and then runs the locked
Playwright Chromium and WebKit projects against `http://127.0.0.1:17866`.

`PhonoFlowBenchmarks` is a Swift package executable used by `performance.yml`.
It accepts `--output <path> --iterations <count>` and writes measured metrics
with machine-checked provenance:

```json
{
  "metrics": {
    "capture_to_pixel_p95_ms": 42.0,
    "spectrogram_throughput_x": 12.0
  },
  "measurements": {
    "capture_to_pixel_p95_ms": {
      "kind": "duration_samples",
      "source": "ContinuousClock from captured chunk through the shared renderer"
    }
  }
}
```

The comparison helper also accepts a `metrics` object/array with optional
`unit`, `lowerIsBetter`, and `maxRegressionPercent` metadata.
The executable must provide every metric named in
`Scripts/ci/validate-benchmarks.py`, and each metric must identify the
instrumentation that produced it. Hosted results are informational but still
enforce absolute gates. Regression comparisons run only on the stable,
self-hosted performance runner.

## Repository and environment settings

The following are required GitHub repository controls. They are external
configuration: committing the workflow does not create or enforce them.

Configure an active branch ruleset for `main` with these required checks:

- `Native (ARM64)`
- `Native (Intel)`
- `WebUI`
- `Fake Scarlett`
- `Native WebUI (chromium)`
- `Native WebUI (webkit)`

Configure an active tag ruleset for stable `vMAJOR.MINOR.PATCH` tags. Restrict
tag creation to release maintainers and restrict tag updates and deletion. The
release workflow independently resolves the remote tag through the GitHub API
and requires it to equal the triggering `GITHUB_SHA` both at startup and
immediately before publication.

Do not run untrusted pull-request code on a self-hosted runner. The hardware
workflow has only manual and scheduled triggers, rejects every ref except
`main`, and uses the protected `hardware-acceptance` environment. The stable
performance job has the same `main`-only restriction.

Set repository variables:

- `PHONOFLOW_PERFORMANCE_RUNNER_ENABLED=true` after registering a trusted runner
  with labels `self-hosted`, `macOS`, and `performance`.
- `PHONOFLOW_FOCUSRITE_RUNNER_ENABLED=true` after registering a trusted runner
  with labels `self-hosted`, `macOS`, and `focusrite`.

Pre-authorize microphone access for the hardware runner account and keep a
class-compliant Focusrite/Scarlett device attached for scheduled runs.

## Releases

Create a protected GitHub environment named `release`, restrict it to stable
`vMAJOR.MINOR.PATCH` tags, require reviewers, and prevent self-review. Enable
[GitHub Release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
before publishing the first release. These settings and the tag ruleset are
external controls and must be audited in repository settings.

Configure this protected environment variable:

- `APPLE_TEAM_ID`

Configure these protected environment secrets:

- `RELEASE_ADMIN_READ_TOKEN`
- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_NOTARY_KEY_P8_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Set `RELEASE_ADMIN_READ_TOKEN` to a fine-grained token limited to this
repository with read-only **Administration** permission. It is used only to
query the immutable-release setting before build work and again immediately
before publication. Encode the `.p12` and App Store Connect Team API `.p8`
files as single-line Base64 values.

The workflow imports the certificate into an ephemeral keychain, builds a
universal Developer ID application, creates a native `hdiutil` DMG, notarizes
and staples it, verifies the mounted application, generates checksums and
dSYMs, and attests all assets. It then creates a draft release with every
asset, verifies that the newest required GitHub Actions check runs for the exact
tag SHA are successful, revalidates the remote tag and immutable-release
setting, and publishes the draft. The final `gh release verify` is also
required to prove the published release is immutable.

No Apple ID password or Developer ID Installer certificate is required.

# Testing and performance

PhonoFlow separates deterministic core behavior, app integration, UI
acceptance, browser acceptance, performance, and physical hardware tests. A
workflow definition is a gate configuration, not proof that the gate has passed
for the current commit.

## Local prerequisites

- macOS 26
- Xcode 26.4 when reproducing the pinned CI environment
- Swift 6 toolchain
- Node.js 24.18.0 for the pinned WebUI CI environment
- dependencies restored from committed SwiftPM and npm lockfiles

The core suite imports Swift Testing. If `xcode-select` points at the standalone
Command Line Tools, select a full Xcode installation first:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Verify the local Xcode selection when reproducing CI:

```bash
export DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer
export PHONOFLOW_XCODE_VERSION=26.4
Scripts/ci/check-xcode.sh
```

## Core tests

Run the Swift package tests:

```bash
swift test \
  --package-path PhonoFlowCore \
  --configuration debug \
  --parallel \
  --enable-code-coverage \
  -Xswiftc -warnings-as-errors
```

The core test suite is expected to cover:

- channel-map generation and validation
- stable route persistence, disconnect, and reconnect
- AUHAL start/configuration failure paths
- input-only capture and output switching
- rate and buffer negotiation
- bounded rings and fanout
- gain, EQ, and limiter behavior
- recording finalization and WAV headers
- pairing, session rotation, routing, SSE, and concurrency

Spectrogram fixtures cover silence, DC, impulse, seeded noise, 1 kHz, 10 kHz,
18 kHz, multitone, stereo-only signals, arbitrary callback boundaries, and
44.1/48/96/192 kHz inputs.

The CI helper runs every tracked local Swift package with deterministic hashing,
coverage, parallel tests, warnings as errors, and locked dependency resolution:

```bash
Scripts/ci/swift-package-tests.sh
```

## Native tests

The shared `PhonoFlow` scheme and CI test plan drive app unit/integration tests:

```bash
xcodebuild test \
  -project PhonoFlow.xcodeproj \
  -scheme PhonoFlow \
  -testPlan PhonoFlow-CI \
  -configuration Debug \
  -destination 'platform=macOS'
```

CI runs this suite on both GitHub's `macos-26` ARM64 runner and
`macos-26-intel` runner. It also runs Swift format linting, static analysis,
warnings-as-errors, coverage enforcement, and a Release build.

Coverage gates are:

- at least 90% line coverage for `PhonoFlowCore` pure core/router code
- at least 80% for non-view production code
- at least 90% for changed executable production lines

Views are intentionally excluded from aggregate production coverage and covered
through UI acceptance.

## WebUI tests

Install exactly the locked dependencies and run unit tests:

```bash
cd WebUI
npm ci
npm test
```

The WebUI uses no runtime CDN dependencies. Unit tests cover API semantics,
state reconciliation, spectrogram rendering, and view behavior.

Playwright acceptance runs against the real Debug application and paired LAN
server in Chromium and WebKit. The acceptance contract uses:

```bash
export PHONOFLOW_ACCEPTANCE=1
export PHONOFLOW_AUDIO_BACKEND=fake
export PHONOFLOW_REMOTE_BIND_HOST=127.0.0.1
export PHONOFLOW_REMOTE_PORT=17866
export PHONOFLOW_PAIRING_CODE=123456
export PHONOFLOW_STATE_DIR="$TMPDIR/phonoflow-acceptance"
export PHONOFLOW_DISABLE_BONJOUR=1
```

These variables are a Debug/acceptance seam. Acceptance is loopback-only and
does not advertise Bonjour. `PHONOFLOW_STATE_DIR` receives
`remote-ready.json` when the listener is ready.

Run a browser project after launching the acceptance build:

```bash
export PHONOFLOW_E2E_EXTERNAL_SERVER=1
export PHONOFLOW_WEBUI_URL=http://127.0.0.1:17866
Scripts/ci/web.sh acceptance chromium
Scripts/ci/web.sh acceptance webkit
```

Both browser projects share one storage-state file under
`PHONOFLOW_PLAYWRIGHT_AUTH_DIR`, so the one-time pairing code is submitted only
once even when Chromium and WebKit run against the same application process.

Acceptance coverage includes pairing, every remote control, state
reconciliation, audio reconnect, authorization failures, keyboard interaction,
WCAG AA contrast, reduced motion, and layouts at 320, 390, 768, and 1440 CSS
pixels.

Native XCUITest uses the same fake four-input Scarlett-style backend for device
selection, hotplug, recording conflict, and reconnect flows.

## Performance gates

Release benchmarks produce JSON and then enforce absolute gates:

```bash
Scripts/ci/run-benchmarks.sh /tmp/phonoflow-performance.json
Scripts/ci/validate-benchmarks.py --profile hosted /tmp/phonoflow-performance.json
Scripts/ci/validate-benchmarks.py --profile stable /tmp/phonoflow-performance.json
```

Required metrics are:

| Metric | Gate |
|---|---:|
| Spectrogram throughput | at least 10× real time |
| Spectrum publication | 15 ± 1 fps |
| Capture-to-pixel p95 | below 150 ms |
| Maximum main-thread stall | below 16.7 ms on stable hardware |
| Analysis operations while hidden | 0 |
| Maximum pending native frames | no more than 1 |
| Steady-state STFT allocations | 0 |

Hosted-runner results enforce every deterministic absolute correctness gate,
require provenance for all metrics, and retain maximum main-thread stall as a
finite, nonnegative diagnostic. The 16.7 ms stall ceiling and strict regression
comparisons run only on an opt-in stable self-hosted runner because scheduler
latency comparisons across changing hosted hardware are not meaningful.

## Focusrite hardware acceptance

Physical hardware tests never run untrusted pull-request code. The optional
workflow is scheduled or manually dispatched in the protected
`hardware-acceptance` environment and requires:

- a trusted self-hosted Mac with labels `self-hosted`, `macOS`, and `focusrite`
- Xcode 26.4
- an attached Focusrite/Scarlett device visible to CoreAudio
- repository variable `PHONOFLOW_FOCUSRITE_RUNNER_ENABLED=true`
- a committed `PhonoFlow-Focusrite` test plan

The default soak is 30 minutes. It must record:

- zero XRUNs
- zero ring overflows
- queue depth never exceeding capacity
- no sustained memory growth

The harness writes `focusrite-metrics.json` and an Xcode result bundle. Treat
the device/model as validated only after reviewing a successful artifact from
the protected runner.

## CI ownership

Recommended protected-branch checks are:

- Native ARM64
- Native Intel
- WebUI
- fake-backend native acceptance
- Chromium and WebKit acceptance

Performance and physical Focusrite workflows complement those required checks;
the hardware workflow is not safe for untrusted pull requests.

# PhonoFlow

PhonoFlow is a native macOS 26 menu-bar application for monitoring, processing,
recording, visualizing, and sharing audio from a turntable or USB audio
interface.

PhonoFlow is macOS-only. Class-compliant Focusrite Scarlett devices and other
multichannel interfaces are supported through CoreAudio/AUHAL; Linux and ALSA
are not part of this project.

## Highlights

- Stable CoreAudio device selection by UID, with selectable stereo input pairs
  for multichannel USB interfaces.
- Input-only capture: meters, recording, analysis, and remote audio do not
  require an output device. Changing an output does not restart capture.
- Two-channel planar Float32 processing with gain, auto-gain, EQ, limiting, and
  explicit AUHAL channel maps.
- Continuous 48 kHz spectrogram analysis with 2,048-point Hann windows, 1,024
  sample hops, 64 logarithmic frequency rows, and a 64-column history.
- Native macOS 26 SwiftUI interface using Liquid Glass for controls and
  navigation while keeping rapidly changing plots on stable, high-contrast
  surfaces.
- Optional paired WebUI for control and listening on a trusted local network.
  It is bundled with the app and makes no CDN or third-party runtime requests.
- Native Apple Silicon and Intel support, with signed and notarized universal
  release automation.

## Requirements

- macOS 26.0 or later
- Xcode 26 for development; CI currently pins Xcode 26.4
- Apple Silicon or Intel Mac
- Microphone permission for audio capture
- A class-compliant CoreAudio input device

Focusrite-specific control features such as phantom power, Air, hardware gain,
firmware updates, and Focusrite Control integration are outside PhonoFlow's
scope.

## Use a multichannel interface

1. Connect the interface before opening PhonoFlow and allow microphone access.
2. Choose the input device by name.
3. Choose an input pair. A Scarlett 2i2 normally exposes `Inputs 1–2`; devices
   with more inputs also expose `Inputs 3–4`, `Inputs 5–6`, and so on.
4. Optionally choose an output and enable Monitor for local passthrough.
5. Enable recording, visualizations, Radio, or Remote Access as needed.

A mono input is duplicated to stereo (`[0, 0]`). A device with two or more
inputs defaults to its first pair (`[0, 1]`). If an interface exposes loopback
as channels 3–4, that pair is selectable as `[2, 3]`; PhonoFlow does not infer
routes from a vendor name.

Routes are persisted against a stable device UID. If a selected interface is
unplugged, PhonoFlow reports it as disconnected, safely finalizes an active
recording, and attempts to restore the same UID and route when it returns.

## Remote Access

Remote Access is disabled by default and runs independently from the legacy
Radio toggle.

1. Open **Settings → Remote Access** and enable it.
2. Generate a six-digit pairing code. The code expires after ten minutes.
3. Open the advertised PhonoFlow address from another device on the same LAN.
4. Enter the code. The browser receives a signed, 30-day, `HttpOnly`,
   `SameSite=Strict` session.

The browser dashboard can select devices and input pairs, control processing,
monitoring, radio and recording, show meters and the spectrogram, and listen to
authenticated PCM16 audio.

> Remote Access v1 uses plain HTTP and is designed only for a trusted local
> network. Do not port-forward it, place it on the public internet, or use it on
> a hostile network. Pairing authenticates control requests but does not encrypt
> traffic.

See [Remote Access and API](docs/remote-access.md) for the security model, API,
SSE events, and audio formats.

## Build from source

```bash
git clone https://github.com/WasinUddy/PhonoFlow.git
cd PhonoFlow
open PhonoFlow.xcodeproj
```

Select the shared `PhonoFlow` scheme and a local Mac destination. From a shell:

```bash
xcodebuild build \
  -project PhonoFlow.xcodeproj \
  -scheme PhonoFlow \
  -configuration Debug \
  -destination 'platform=macOS'
```

The application target is native SwiftUI/AppKit. Testable audio, routing, DSP,
authentication, and spectrogram behavior live in the local Swift 6
`PhonoFlowCore` package.

## Test

Make sure the full Xcode toolchain is selected; the standalone Command Line
Tools installation does not include the Swift Testing module used by the core
suite:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Run the portable core tests and WebUI unit tests:

```bash
swift test --package-path PhonoFlowCore

cd WebUI
npm ci
npm test
```

Xcode unit, integration, and acceptance suites require Xcode 26 and the
committed shared schemes/test plans. Performance and hardware acceptance have
additional requirements described in [Testing and performance](docs/testing.md).

Physical Focusrite soak results and signed/notarized release verification are
environment-specific gates. The presence of the workflow or test harness alone
is not evidence that a particular device or release credential has been
validated.

## Documentation

- [Architecture](docs/architecture.md)
- [Remote Access and API](docs/remote-access.md)
- [Testing and performance](docs/testing.md)
- [Release signing and notarization](docs/releasing.md)
- [Compatibility and migration](docs/compatibility.md)
- [Accessibility](docs/accessibility.md)

## Installation

For a published release, download the universal DMG, matching dSYM archive, and
checksum file from the repository's
[GitHub Releases](https://github.com/WasinUddy/PhonoFlow/releases).
Release artifacts are expected to be Developer ID signed, notarized, stapled,
and accompanied by provenance. Do not bypass Gatekeeper for an artifact that
fails verification.

## License

All rights reserved.

# Compatibility and migration

## Platform support

PhonoFlow requires macOS 26 and Xcode 26. It is built as a universal application
for Apple Silicon and Intel Macs.

The application uses CoreAudio/AUHAL. It does not support Linux, ALSA, Windows,
or iOS.

## Audio devices

Support covers class-compliant PCM input exposed by CoreAudio:

- selectable channel pairs
- input-only capture
- monitoring/passthrough
- meters and visualizations
- Float32 recording
- browser and legacy network streaming

Focusrite Scarlett interfaces are not special-cased. Channel availability and
names come from CoreAudio. Features owned by Focusrite firmware/control
software—phantom power, Air, hardware gain, clock configuration, firmware
updates, and mixer routing—remain outside the application.

Aggregate, virtual, Bluetooth, and other CoreAudio devices may be enumerated,
but their latency, clocking, and supported formats depend on the device driver.
Do not infer hardware acceptance from enumeration alone.

## Preference migration

The enhancement preserves:

- color themes
- launch-at-login preference
- basic/pro and advanced visualization preferences
- Radio port and allowed-host settings
- stable device UID preferences
- Float32 recordings
- the legacy `/stream` wire format

Audio selection now has three stable fields:

```text
inputUID + inputRouteID + optional outputUID
```

Old numeric `AudioDeviceID` values are not migrated because they are transient.
An existing stable input UID uses its saved valid route when present and
otherwise defaults to the first valid input pair. Existing output UIDs remain
optional.

Route defaults are:

- one input channel: `[0, 0]`
- two or more input channels: `[0, 1]`
- subsequent exposed pairs: `[2, 3]`, `[4, 5]`, and so on

If a saved route no longer exists after a driver or device-layout change,
PhonoFlow selects the first valid route and presents the negotiated format.

## Radio and Remote Access

Radio and Remote Access are separate:

- Remote Access is disabled by default and owns the paired dashboard, API, SSE,
  and authenticated `/audio/live.wav`.
- Radio controls the compatibility `/stream` endpoint.
- Turning Radio off does not stop the Remote Access server.

For existing VLC/mpv clients, `/stream` remains stereo Float32. New
installations protect it with the paired session by default. The explicit
`allowLegacyUnauthenticatedStream` preference preserves an unauthenticated
trusted-LAN compatibility mode; enabling it reduces security.

Remote Access uses a separate default port (`7866`) from the legacy Radio port
(`7865`), so existing Radio configuration is not silently repurposed.

## Recording and device changes

Recordings remain Float32. Input device, input pair, and sample-rate changes are
blocked while recording so a file cannot change format midstream. Remote
commands receive `409 Conflict`.

New recordings are stored in the sandbox-safe
`~/Library/Application Support/PhonoFlow/Recordings` location and remain
discoverable through the native “Show in Finder” action. Existing files in
`~/Music/PhonoFlow Recordings` are left untouched.

If the active input is unplugged, the recorder finalizes the file before the
engine enters `disconnected`. Reconnection uses the stable device UID and saved
route.

## Visual changes

macOS 26 Liquid Glass changes the presentation of navigation, status, selectors,
and actions, but visualization surfaces remain opaque/high contrast for stable
waveform and spectrogram reading. All five existing themes remain available.

Reduced motion, reduced transparency, keyboard navigation, VoiceOver labels,
and sufficient contrast are compatibility requirements rather than optional
themes. See [Accessibility](accessibility.md).

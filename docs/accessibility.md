# Accessibility

Accessibility applies to both the native macOS 26 interface and the paired
WebUI. Visual similarity to Liquid Glass must never take priority over
legibility or operability.

## Native macOS interface

The SwiftUI interface must:

- expose every device, route, processing control, status, and action through
  keyboard navigation
- provide meaningful VoiceOver labels, values, hints, and state announcements
- avoid communicating engine, recording, streaming, or error state through
  color alone
- meet adequate text/icon contrast across every theme and system appearance
- honor Reduce Motion and avoid nonessential matched-geometry/materialization
  transitions when it is enabled
- honor Reduce Transparency with more opaque control surfaces
- retain stable high-contrast plot backgrounds behind waveform, phase, and
  spectrogram data
- keep focus visible and in a predictable reading order
- expose actionable CoreAudio errors instead of relying on a transient visual
  indicator

Native Liquid Glass is used for navigation, controls, and status. It is not
stacked behind rapidly changing visualization pixels.

## WebUI

The dashboard must:

- use semantic landmarks, headings, forms, labels, buttons, and status regions
- preserve complete keyboard operation and visible `:focus-visible` treatment
- announce pairing, reconnect, engine, recording, and request errors in an
  appropriate live region
- maintain WCAG AA contrast in light, dark, and accent themes
- support `prefers-reduced-motion: reduce`
- provide solid or more opaque fallbacks for
  `prefers-reduced-transparency: reduce` where available
- remain usable at 320, 390, 768, and 1440 CSS pixels without horizontal
  control loss
- give meter and spectrogram canvases equivalent textual state/labels
- keep browser listening controls understandable when autoplay is blocked

CSS translucency is an interpretation of the native design language, not a
claim that the browser implements Apple's material.

## Acceptance checklist

Before release:

1. Traverse the native popover and Settings using only the keyboard.
2. Inspect the VoiceOver rotor and confirm labels, values, and state changes.
3. Enable Reduce Motion and Reduce Transparency in macOS settings.
4. Verify every native theme in light and dark appearance.
5. Run Chromium and WebKit Playwright accessibility scans at all required
   viewport widths.
6. Verify pairing, disconnect/reconnect, recording conflict, and CoreAudio
   failure announcements.
7. Confirm focus is preserved or deliberately moved after asynchronous state
   reconciliation.
8. Confirm plots remain readable without animation and that their current state
   has a nonvisual description.

Passing automated contrast and accessibility scans is necessary but not
sufficient; keyboard and VoiceOver behavior require manual acceptance before a
release is described as accessible.

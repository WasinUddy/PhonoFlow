# Remote Access and API

Remote Access is an optional paired HTTP service for devices on the same trusted
LAN. It is disabled by default and has a lifecycle independent of Radio. When
enabled, PhonoFlow advertises `_phonoflow._tcp` through Bonjour and serves the
bundled dashboard, API, SSE feed, and authenticated browser audio.

The application uses Hummingbird 2.x as its HTTP edge. Routing,
authorization, state transitions, and response semantics remain
transport-independent so they can be tested without a live listener.

## Security boundary

Remote Access v1 is authenticated but not encrypted:

- Use it only on a trusted private network.
- Do not configure router port forwarding.
- Do not expose it through a public reverse proxy without designing and
  reviewing a separate TLS/authentication boundary.
- Anyone able to observe LAN traffic may see audio and HTTP data.
- Pair only browsers and devices you trust.

The server deliberately does not enable CORS or load any CDN resources.

## Pairing and sessions

The native Settings interface generates a six-digit pairing code. A code is
valid for ten minutes and is consumed after successful use. Each source IP is
limited to five failed attempts per ten-minute window.

Successful pairing creates a signed session valid for 30 days. The cookie is
named `PhonoFlowSession` and has:

```text
Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict
```

The HMAC-SHA256 signing secret and session epoch are stored in the user's
Keychain. **Revoke all browsers** rotates the secret/epoch and closes
authenticated SSE and audio subscriptions. Logout revokes the current session.

The v1 trusted-LAN service uses HTTP, so a `Secure` cookie attribute cannot be
used. That is another reason not to expose it beyond the LAN.

## Request protections

The server enforces all of the following:

- an exact, current local-interface, localhost, or advertised `.local` `Host`
  authority, including the bound port
- canonical, exact routes with no encoded aliases or query parameters
- exact same-origin `Origin` on mutations
- `Content-Type: application/json` on mutations
- `X-PhonoFlow-Mutation: 1` on mutations
- endpoint-specific body-size limits
- per-source request and pairing limits
- authenticated sessions on control, events, and browser audio
- a restrictive Content Security Policy and related browser headers
- no `Access-Control-Allow-*` headers
- bounded event/audio clients and slow-client eviction

Problems use `application/problem+json`. The control surface can return standard
validation and routing errors in addition to the principal API statuses:
`401`, `403`, `404`, `405`, `409`, `422`, and `503`.

## API v1

All mutations are idempotent desired-state commands. A successful command
returns the authoritative snapshot with a monotonically increasing `revision`.
Do not treat a local optimistic value as final; reconcile it with the response
or the next SSE state event.

| Method | Route | Session | Purpose |
|---|---|:---:|---|
| `POST` | `/api/v1/auth/pair` | No | Exchange `{"code":"123456"}` for a browser session and snapshot |
| `POST` | `/api/v1/auth/logout` | Yes | Revoke the current session |
| `GET` | `/api/v1/state` | Yes | Read the latest authoritative snapshot |
| `GET` | `/api/v1/events` | Yes | Subscribe to server-sent events |
| `POST` | `/api/v1/devices/refresh` | Yes | Refresh CoreAudio devices |
| `PUT` | `/api/v1/audio/selection` | Yes | Select stable input UID, route ID, and optional output UID |
| `PUT` | `/api/v1/monitor` | Yes | Set `{"enabled":true\|false}` |
| `PUT` | `/api/v1/processing` | Yes | Set linear gain, auto-gain, or processing enabled state |
| `PUT` | `/api/v1/equalizer` | Yes | Set enabled state and/or ten EQ bands |
| `PUT` | `/api/v1/radio` | Yes | Set the legacy Radio state |
| `PUT` | `/api/v1/recording` | Yes | Start or stop recording |
| `GET` | `/audio/live.wav` | Yes | Stream stereo PCM16/48 kHz WAV for browser playback |
| `GET` | `/stream` | Configurable | Preserve the legacy stereo Float32 stream for VLC/mpv |

Selection payload:

```json
{
  "inputUID": "AppleUSBAudioEngine:example-input",
  "inputRouteID": "channels-1-2",
  "outputUID": null
}
```

Processing payloads may update any supplied field. `gain` is linear and must be
finite in the range `0...4`; the WebUI's dB control converts to this value:

```json
{
  "gain": 1.2589254,
  "autoGainEnabled": false,
  "enabled": true
}
```

The EQ contains exactly ten positive-frequency bands with gains from −24 dB
through +24 dB:

```json
{
  "enabled": true,
  "bands": [
    { "frequencyHz": 31, "gainDB": 0 },
    { "frequencyHz": 62, "gainDB": 0 },
    { "frequencyHz": 125, "gainDB": 0 },
    { "frequencyHz": 250, "gainDB": 0 },
    { "frequencyHz": 500, "gainDB": 0 },
    { "frequencyHz": 1000, "gainDB": 0 },
    { "frequencyHz": 2000, "gainDB": 0 },
    { "frequencyHz": 4000, "gainDB": 0 },
    { "frequencyHz": 8000, "gainDB": 0 },
    { "frequencyHz": 16000, "gainDB": 0 }
  ]
}
```

Input device, route, or sample-rate changes while recording return `409
Conflict`. Invalid selections return `422`; temporarily unavailable audio
services return `503`.

## State and SSE

A state snapshot includes:

- `revision` and generation time
- typed engine phase, negotiated format, and actionable problem
- devices, stable UIDs, routes, rates, transport, and connection state
- current selection
- meters and processing/EQ state
- monitor, Radio, recording, and listener state
- performance diagnostics

`GET /api/v1/events` sends a complete `snapshot` immediately. It then sends
discrete `state` changes, `meters` at no more than 10 Hz, 64-byte `spectrogram`
columns at no more than 15 Hz, and heartbeat comments every 15 seconds. A
reconnect always begins with the newest snapshot.

Event and audio queues are bounded. Telemetry values are coalesced to the newest
sample, while authoritative state remains a resynchronization point. Persistently
slow clients are disconnected rather than allowed to create unbounded memory or
latency.

## Audio compatibility

`/audio/live.wav` is an authenticated, chunked, stereo PCM16/48 kHz WAV stream
intended for browser playback. Its header uses streaming sentinel sizes.

`/stream` preserves the existing Float32 wire format for VLC/mpv compatibility
and remains gated by Radio. New installations keep it authenticated by default.
An explicit compatibility preference may allow unauthenticated legacy clients;
that weakens the security boundary and should be used only on a trusted LAN.

Remote Access remains available when Radio is off; only `/stream` depends on
Radio.

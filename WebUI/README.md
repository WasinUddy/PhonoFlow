# PhonoFlow WebUI

This directory is a dependency-free production dashboard bundled by the native PhonoFlow app. Runtime assets are plain semantic HTML, CSS, and ES modules; development dependencies are test-only.

## Server contract

- Serve `index.html`, `styles.css`, and `src/*.js` from the same origin as the API.
- Pairing uses an `HttpOnly; SameSite=Strict` cookie. All `PUT` and `POST` requests send `X-PhonoFlow-Mutation: 1`.
- The dashboard consumes `/api/v1/state`, `/api/v1/events`, the versioned mutation routes, and authenticated `/audio/live.wav`.
- SSE may use named `snapshot`, `state`, `meters`, `spectrogram`, and `problem` events, or an unnamed `{ "type", "payload" }` envelope.
- A spectrogram event contains a sequence, timestamp, and exactly 64 intensity bytes as a JSON array or base64.
- State changes are authoritative and revisioned. The browser does not optimistically change controls.

The WebUI makes no third-party runtime requests. The native server must also set CSP, clickjacking, MIME-sniffing, Host, Origin, rate-limit, and exact-route protections.

## Tests

```sh
npm ci
npm run test:coverage
npm run test:acceptance -- --project=chromium
npm run test:acceptance -- --project=webkit
```

`test:coverage` measures every production module and enforces the configured
line, branch, function, and statement minimums, including 90% aggregate line
coverage. CI also runs `coverage:gate` against the base commit and requires 90%
coverage of changed executable lines. Playwright normally starts the
deterministic fixture server at `http://127.0.0.1:4173`; the fixture models the
production one-time pairing code and named meter/spectrogram SSE events.

To test a running native app, use a fresh authentication directory for the
run. The setup projects coordinate through one atomic storage-state file,
exchange the pairing code exactly once, and reuse the same `HttpOnly` session
for every isolated dashboard test and browser engine:

```sh
PHONOFLOW_E2E_EXTERNAL_SERVER=1 \
PHONOFLOW_WEBUI_URL=http://127.0.0.1:17866 \
PHONOFLOW_PAIRING_CODE=042042 \
PHONOFLOW_PLAYWRIGHT_AUTH_DIR="$(mktemp -d /tmp/phonoflow-playwright-auth.XXXXXX)" \
npm run test:acceptance -- --project=chromium
```

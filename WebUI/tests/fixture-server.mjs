import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createFixtureState, pairingCode } from "./fixtures/state.js";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const port = Number(process.env.PORT ?? 4173);
let state = createFixtureState();
let pairingCodeAvailable = true;
let successfulPairings = 0;
const eventClients = new Set();
const audioClients = new Set();

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

function securityHeaders(contentType) {
  return {
    "Cache-Control": "no-store",
    "Content-Type": contentType,
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; media-src 'self'; font-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  };
}

function sendJSON(response, status, body, extraHeaders = {}) {
  response.writeHead(status, {
    ...securityHeaders("application/json; charset=utf-8"),
    ...extraHeaders,
  });
  response.end(body === null ? undefined : JSON.stringify(body));
}

function sendProblem(response, status, title, detail) {
  sendJSON(response, status, {
    type: `https://phonoflow.local/problems/${status}`,
    title,
    status,
    detail,
  }, { "Content-Type": "application/problem+json; charset=utf-8" });
}

function isPaired(request) {
  return /(?:^|;\s*)phonoflow_session=paired(?:;|$)/.test(request.headers.cookie ?? "");
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 32_768) throw new RangeError("Body too large");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function advanceRevision() {
  state.revision += 1;
}

function broadcast(type, payload) {
  const message = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  for (const client of eventClients) client.write(message);
}

function streamingWAVHeader() {
  const sampleRate = 48_000;
  const channels = 2;
  const buffer = Buffer.alloc(44);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(0x7fff_ffff, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(channels, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * channels * 2, 28);
  buffer.writeUInt16LE(channels * 2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(0x7fff_ffdb, 40);
  return buffer;
}

function pcmChunk(startFrame, frames = 960) {
  const sampleRate = 48_000;
  const channels = 2;
  const buffer = Buffer.alloc(frames * channels * 2);
  for (let frame = 0; frame < frames; frame += 1) {
    const value = Math.round(
      Math.sin((2 * Math.PI * 440 * (startFrame + frame)) / sampleRate) * 12_000,
    );
    const offset = frame * channels * 2;
    buffer.writeInt16LE(value, offset);
    buffer.writeInt16LE(value, offset + 2);
  }
  return buffer;
}

function publishAudioListenerCount() {
  if (state.radio.listenerCount === audioClients.size) return;
  state.radio.listenerCount = audioClients.size;
  advanceRevision();
  broadcast("state", state);
}

function removeAudioClient(client, { end = false } = {}) {
  if (!audioClients.delete(client)) return;
  clearInterval(client.timer);
  if (end && !client.response.destroyed && !client.response.writableEnded) {
    client.response.end();
  }
  publishAudioListenerCount();
}

function closeAudioClients() {
  for (const client of [...audioClients]) {
    removeAudioClient(client, { end: true });
  }
}

function serveLiveWAV(response) {
  response.writeHead(200, {
    "Accept-Ranges": "none",
    "Cache-Control": "no-store",
    "Content-Type": "audio/wav",
    "X-Content-Type-Options": "nosniff",
  });

  const header = streamingWAVHeader();
  response.write(header.subarray(0, 13));
  response.write(header.subarray(13, 43));
  response.write(header.subarray(43));

  const client = {
    frame: 0,
    response,
    timer: null,
  };
  const writePCM = () => {
    if (response.destroyed || response.writableEnded) {
      removeAudioClient(client);
      return;
    }
    if (response.writableLength > 64 * 1_024) return;
    const chunk = pcmChunk(client.frame);
    client.frame += 960;
    // Split inside a four-byte stereo frame so acceptance exercises the same
    // arbitrary network boundaries as a real chunked response.
    response.write(chunk.subarray(0, 1_919));
    response.write(chunk.subarray(1_919));
  };
  client.timer = setInterval(writePCM, 20);
  audioClients.add(client);
  response.on("close", () => removeAudioClient(client));
  publishAudioListenerCount();
  writePCM();
}

async function serveAsset(request, response, pathname) {
  const relative = pathname === "/" ? "index.html" : pathname.slice(1);
  const absolute = resolve(root, relative);
  if (absolute !== root && !absolute.startsWith(`${root}${sep}`)) {
    sendProblem(response, 404, "Not found", "No route exists at this path.");
    return;
  }
  try {
    const body = await readFile(absolute);
    const contentType = mimeTypes[extname(absolute)] ?? "application/octet-stream";
    response.writeHead(200, {
      ...securityHeaders(contentType),
      "Content-Length": body.length,
    });
    response.end(body);
  } catch {
    sendProblem(response, 404, "Not found", "No route exists at this path.");
  }
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`);
  const path = url.pathname;
  const method = request.method ?? "GET";

  try {
    if (path === "/api/v1/auth/pair" && method === "POST") {
      const body = await readJSON(request);
      if (!pairingCodeAvailable || body.code !== pairingCode) {
        sendProblem(response, 401, "Pairing failed", "That code is invalid or expired.");
        return;
      }
      pairingCodeAvailable = false;
      successfulPairings += 1;
      state = createFixtureState();
      sendJSON(response, 200, { paired: true }, {
        "Set-Cookie": "phonoflow_session=paired; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000",
      });
      return;
    }

    if (path === "/api/v1/auth/logout" && method === "POST") {
      sendJSON(response, 204, null, {
        "Set-Cookie": "phonoflow_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
      });
      return;
    }

    if (path.startsWith("/__fixture__/")) {
      const body = method === "POST" ? await readJSON(request) : {};
      if (path === "/__fixture__/stats" && method === "GET") {
        sendJSON(response, 200, {
          audioClients: audioClients.size,
          eventClients: eventClients.size,
          successfulPairings,
        });
        return;
      }
      if (path === "/__fixture__/event" && method === "POST") {
        broadcast(String(body.type ?? "message"), body.payload ?? {});
        sendJSON(response, 204, null);
        return;
      }
      if (path === "/__fixture__/disconnect" && method === "POST") {
        for (const client of eventClients) client.end();
        eventClients.clear();
        sendJSON(response, 204, null);
        return;
      }
      if (path === "/__fixture__/reset" && method === "POST") {
        closeAudioClients();
        state = createFixtureState();
        pairingCodeAvailable = true;
        successfulPairings = 0;
        sendJSON(response, 200, state);
        return;
      }
      sendProblem(response, 404, "Not found", "Unknown test fixture route.");
      return;
    }

    if (path.startsWith("/api/") || path === "/audio/live.wav") {
      if (!isPaired(request)) {
        sendProblem(response, 401, "Pairing required", "Pair this browser from PhonoFlow Settings.");
        return;
      }
    }

    if (path === "/api/v1/state" && method === "GET") {
      sendJSON(response, 200, state);
      return;
    }

    if (path === "/api/v1/events" && method === "GET") {
      response.writeHead(200, {
        ...securityHeaders("text/event-stream; charset=utf-8"),
        Connection: "keep-alive",
      });
      response.write(`event: snapshot\ndata: ${JSON.stringify(state)}\n\n`);
      response.write(": connected\n\n");
      eventClients.add(response);
      request.on("close", () => eventClients.delete(response));
      return;
    }

    if (path === "/api/v1/devices/refresh" && method === "POST") {
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/audio/selection" && method === "PUT") {
      if (state.recording.enabled) {
        sendProblem(response, 409, "Recording in progress", "Stop recording before changing the input.");
        return;
      }
      const body = await readJSON(request);
      state.selection = {
        inputUID: body.inputUID ?? null,
        inputRouteID: body.inputRouteID ?? null,
        outputUID: body.outputUID ?? null,
      };
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/monitor" && method === "PUT") {
      state.monitor.enabled = Boolean((await readJSON(request)).enabled);
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/radio" && method === "PUT") {
      state.radio.enabled = Boolean((await readJSON(request)).enabled);
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/recording" && method === "PUT") {
      state.recording.enabled = Boolean((await readJSON(request)).enabled);
      state.recording.fileName = state.recording.enabled ? "PhonoFlow-test.wav" : null;
      state.recording.durationSeconds = state.recording.enabled ? 1 : 0;
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/processing" && method === "PUT") {
      const body = await readJSON(request);
      state.processing = {
        gain: body.gain === undefined ? state.processing.gain : Number(body.gain),
        autoGainEnabled: body.autoGainEnabled === undefined
          ? state.processing.autoGainEnabled
          : Boolean(body.autoGainEnabled),
        enabled: body.enabled === undefined
          ? state.processing.enabled
          : Boolean(body.enabled),
      };
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/api/v1/equalizer" && method === "PUT") {
      state.equalizer.bands = (await readJSON(request)).bands;
      advanceRevision();
      sendJSON(response, 200, state);
      broadcast("state", state);
      return;
    }

    if (path === "/audio/live.wav" && method === "GET") {
      serveLiveWAV(response);
      return;
    }

    if (method === "GET" && !path.startsWith("/api/")) {
      await serveAsset(request, response, path);
      return;
    }

    sendProblem(response, 404, "Not found", "No route exists at this path.");
  } catch (error) {
    const status = error instanceof RangeError ? 413 : 400;
    sendProblem(response, status, "Invalid request", error.message);
  }
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`PhonoFlow WebUI fixture listening on http://127.0.0.1:${port}\n`);
});

function shutdown() {
  closeAudioClients();
  for (const client of eventClients) client.end();
  server.close(() => process.exit(0));
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

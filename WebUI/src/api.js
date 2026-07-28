export const MUTATION_HEADER = "X-PhonoFlow-Mutation";
export const MUTATION_HEADER_VALUE = "1";

export class ApiProblem extends Error {
  constructor(problem, response) {
    const title = String(problem?.title ?? `Request failed (${response?.status ?? "network"})`);
    const detail = String(problem?.detail ?? "");
    super(detail ? `${title}: ${detail}` : title);
    this.name = "ApiProblem";
    this.title = title;
    this.detail = detail;
    this.status = Number(problem?.status ?? response?.status ?? 0);
    this.type = problem?.type ?? "about:blank";
    this.instance = problem?.instance ?? null;
    this.code = problem?.code ?? null;
    this.fieldErrors = problem?.fieldErrors ?? null;
    this.currentRevision = problem?.currentRevision ?? null;
    this.retryable = Boolean(problem?.retryable);
  }
}

export class NetworkError extends Error {
  constructor(message, cause) {
    super(message, { cause });
    this.name = "NetworkError";
  }
}

function isJSON(contentType) {
  return /\b(?:application\/json|application\/problem\+json)\b/i.test(contentType ?? "");
}

async function parseResponseBody(response) {
  if (response.status === 204 || response.status === 205) return null;
  const contentType = response.headers?.get?.("content-type") ?? "";
  if (isJSON(contentType)) {
    try {
      return await response.json();
    } catch {
      return null;
    }
  }
  const text = await response.text();
  return text ? { detail: text } : null;
}

export class PhonoFlowAPI {
  constructor({
    fetchImpl = globalThis.fetch?.bind(globalThis),
    baseURL = "",
  } = {}) {
    if (!fetchImpl) throw new TypeError("A fetch implementation is required.");
    this.fetch = fetchImpl;
    this.baseURL = baseURL.replace(/\/$/, "");
  }

  async request(path, { method = "GET", body, signal, mutation = false } = {}) {
    const headers = new Headers({ Accept: "application/json" });
    const requestBody = mutation && body === undefined ? {} : body;
    if (requestBody !== undefined) headers.set("Content-Type", "application/json");
    if (mutation) headers.set(MUTATION_HEADER, MUTATION_HEADER_VALUE);

    let response;
    try {
      response = await this.fetch(`${this.baseURL}${path}`, {
        method,
        credentials: "same-origin",
        headers,
        body: requestBody === undefined ? undefined : JSON.stringify(requestBody),
        signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new NetworkError("Could not reach PhonoFlow on this Mac.", error);
    }

    const payload = await parseResponseBody(response);
    if (!response.ok) {
      throw new ApiProblem(payload, response);
    }
    return payload;
  }

  getState(options) {
    return this.request("/api/v1/state", options);
  }

  pair(code, options = {}) {
    if (!/^[0-9]{6}$/.test(String(code))) {
      throw new TypeError("Enter the six-digit pairing code.");
    }
    return this.request("/api/v1/auth/pair", {
      ...options,
      method: "POST",
      mutation: true,
      body: { code: String(code) },
    });
  }

  logout(options = {}) {
    return this.request("/api/v1/auth/logout", {
      ...options,
      method: "POST",
      mutation: true,
    });
  }

  refreshDevices(options = {}) {
    return this.request("/api/v1/devices/refresh", {
      ...options,
      method: "POST",
      mutation: true,
    });
  }

  updateSelection(selection, options = {}) {
    return this.request("/api/v1/audio/selection", {
      ...options,
      method: "PUT",
      mutation: true,
      body: {
        inputUID: selection.inputUID || null,
        inputRouteID: selection.inputRouteID || null,
        outputUID: selection.outputUID || null,
      },
    });
  }

  updateMonitor(enabled, options = {}) {
    return this.updateEnabled("/api/v1/monitor", enabled, options);
  }

  updateRadio(enabled, options = {}) {
    return this.updateEnabled("/api/v1/radio", enabled, options);
  }

  updateRecording(enabled, options = {}) {
    return this.updateEnabled("/api/v1/recording", enabled, options);
  }

  updateEnabled(path, enabled, options = {}) {
    return this.request(path, {
      ...options,
      method: "PUT",
      mutation: true,
      body: { enabled: Boolean(enabled) },
    });
  }

  updateProcessing(processing, options = {}) {
    const body = {};
    if (processing.gain !== undefined) body.gain = Number(processing.gain);
    if (processing.autoGainEnabled !== undefined) {
      body.autoGainEnabled = Boolean(processing.autoGainEnabled);
    }
    if (processing.enabled !== undefined) body.enabled = Boolean(processing.enabled);
    return this.request("/api/v1/processing", {
      ...options,
      method: "PUT",
      mutation: true,
      body,
    });
  }

  updateEqualizer(bands, options = {}) {
    return this.request("/api/v1/equalizer", {
      ...options,
      method: "PUT",
      mutation: true,
      body: {
        bands: bands.map((band) => ({
          frequencyHz: Number(band.frequencyHz),
          gainDB: Number(band.gainDB),
        })),
      },
    });
  }
}

export function parseEventPayload(type, data) {
  if (!data || !String(data).trim()) return null;
  let parsed;
  try {
    parsed = JSON.parse(data);
  } catch {
    return null;
  }

  if (type && type !== "message") {
    return { type, payload: parsed?.payload ?? parsed };
  }

  const envelopeType = parsed?.type ?? parsed?.event;
  if (!envelopeType) return { type: "state", payload: parsed };
  return {
    type: String(envelopeType),
    payload: parsed.payload ?? parsed.data ?? parsed,
  };
}

export class EventStream {
  constructor({
    EventSourceImpl = globalThis.EventSource,
    setTimeoutImpl = globalThis.setTimeout?.bind(globalThis),
    clearTimeoutImpl = globalThis.clearTimeout?.bind(globalThis),
    url = "/api/v1/events",
  } = {}) {
    this.EventSourceImpl = EventSourceImpl;
    this.setTimeout = setTimeoutImpl;
    this.clearTimeout = clearTimeoutImpl;
    this.url = url;
    this.source = null;
    this.retryTimer = null;
    this.retryAttempt = 0;
    this.running = false;
    this.handlers = {};
  }

  start(handlers) {
    this.stop();
    this.handlers = handlers ?? {};
    this.running = true;
    this.connect();
  }

  connect() {
    if (!this.running || !this.EventSourceImpl) return;
    const source = new this.EventSourceImpl(this.url, { withCredentials: true });
    this.source = source;

    source.onopen = () => {
      if (!this.running || source !== this.source) return;
      this.retryAttempt = 0;
      this.handlers.onConnection?.("connected");
    };

    const eventTypes = ["snapshot", "state", "meters", "spectrogram", "problem"];
    for (const type of eventTypes) {
      source.addEventListener?.(type, (event) => {
        if (!this.running || source !== this.source) return;
        const parsed = parseEventPayload(type, event.data);
        if (parsed) this.handlers.onEvent?.(parsed);
      });
    }

    source.onmessage = (event) => {
      if (!this.running || source !== this.source) return;
      const parsed = parseEventPayload("message", event.data);
      if (parsed) this.handlers.onEvent?.(parsed);
    };

    source.onerror = () => {
      if (!this.running || source !== this.source) return;
      source.close();
      this.source = null;
      this.handlers.onConnection?.("reconnecting");
      const delay = Math.min(15_000, 1_000 * (2 ** this.retryAttempt));
      this.retryAttempt += 1;
      this.retryTimer = this.setTimeout?.(() => this.connect(), delay);
    };
  }

  stop() {
    this.running = false;
    this.source?.close();
    this.source = null;
    if (this.retryTimer !== null) this.clearTimeout?.(this.retryTimer);
    this.retryTimer = null;
    this.retryAttempt = 0;
  }
}

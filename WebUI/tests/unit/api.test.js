import { describe, expect, it, vi } from "vitest";
import {
  ApiProblem,
  EventStream,
  MUTATION_HEADER,
  PhonoFlowAPI,
  parseEventPayload,
} from "../../src/api.js";

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { "Content-Type": init.contentType ?? "application/json" },
  });
}

describe("PhonoFlow API", () => {
  it("sends the approved pairing request and mutation header", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ paired: true }));
    const api = new PhonoFlowAPI({ fetchImpl });
    await api.pair("123456");

    expect(fetchImpl).toHaveBeenCalledOnce();
    const [path, init] = fetchImpl.mock.calls[0];
    expect(path).toBe("/api/v1/auth/pair");
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("same-origin");
    expect(init.headers.get(MUTATION_HEADER)).toBe("1");
    expect(JSON.parse(init.body)).toEqual({ code: "123456" });
  });

  it("validates pairing codes before network access", () => {
    const fetchImpl = vi.fn();
    const api = new PhonoFlowAPI({ fetchImpl });

    expect(() => api.pair("12a456")).toThrow("six-digit");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it.each([
    ["updateSelection", [{ inputUID: "in", inputRouteID: "pair", outputUID: null }], "/api/v1/audio/selection", {
      inputUID: "in", inputRouteID: "pair", outputUID: null,
    }],
    ["updateMonitor", [true], "/api/v1/monitor", { enabled: true }],
    ["updateRadio", [false], "/api/v1/radio", { enabled: false }],
    ["updateRecording", [true], "/api/v1/recording", { enabled: true }],
  ])("builds %s requests", async (method, args, expectedPath, expectedBody) => {
    const fetchImpl = vi.fn(async () => new Response(null, { status: 204 }));
    const api = new PhonoFlowAPI({ fetchImpl });
    await api[method](...args);

    const [path, init] = fetchImpl.mock.calls[0];
    expect(path).toBe(expectedPath);
    expect(init.method).toBe("PUT");
    expect(JSON.parse(init.body)).toEqual(expectedBody);
    expect(init.headers.get(MUTATION_HEADER)).toBe("1");
  });

  it("sends the native linear processing gain", async () => {
    const fetchImpl = vi.fn(async () => new Response(null, { status: 204 }));
    const api = new PhonoFlowAPI({ fetchImpl });
    await api.updateProcessing({ gain: 2, gainDB: 6.02, autoGainEnabled: true });

    const body = JSON.parse(fetchImpl.mock.calls[0][1].body);
    expect(body).toEqual({ gain: 2, autoGainEnabled: true });
  });

  it("can toggle auto gain without changing a muted gain", async () => {
    const fetchImpl = vi.fn(async () => new Response(null, { status: 204 }));
    const api = new PhonoFlowAPI({ fetchImpl });
    await api.updateProcessing({ autoGainEnabled: true });

    expect(JSON.parse(fetchImpl.mock.calls[0][1].body)).toEqual({ autoGainEnabled: true });
  });

  it("preserves structured problem details", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({
      type: "https://phonoflow.local/problems/recording-conflict",
      title: "Recording in progress",
      status: 409,
      detail: "Stop recording before changing inputs.",
      fieldErrors: { inputUID: "locked" },
      currentRevision: 8,
    }, { status: 409, contentType: "application/problem+json" }));
    const api = new PhonoFlowAPI({ fetchImpl });

    await expect(api.updateSelection({
      inputUID: "other",
      inputRouteID: "pair",
      outputUID: null,
    })).rejects.toMatchObject({
      name: "ApiProblem",
      status: 409,
      title: "Recording in progress",
      currentRevision: 8,
      fieldErrors: { inputUID: "locked" },
    });
  });

  it("handles empty successful responses", async () => {
    const fetchImpl = vi.fn(async () => new Response(null, { status: 204 }));
    const api = new PhonoFlowAPI({ fetchImpl });
    await expect(api.logout()).resolves.toBeNull();
    expect(fetchImpl.mock.calls[0][1].headers.get("Content-Type")).toBe("application/json");
    expect(fetchImpl.mock.calls[0][1].body).toBe("{}");
  });
});

describe("SSE parsing and reconnect", () => {
  it("parses named and envelope events without executing malformed input", () => {
    expect(parseEventPayload("meters", '{"sequence":2,"left":0.5}')).toEqual({
      type: "meters",
      payload: { sequence: 2, left: 0.5 },
    });
    expect(parseEventPayload("message", '{"type":"state","payload":{"revision":3}}')).toEqual({
      type: "state",
      payload: { revision: 3 },
    });
    expect(parseEventPayload("message", "{broken")).toBeNull();
  });

  it("opens a same-origin event source and retries with backoff", () => {
    class FakeEventSource {
      constructor(url, options) {
        this.url = url;
        this.options = options;
        this.listeners = {};
        FakeEventSource.instances.push(this);
      }
      addEventListener(type, handler) {
        this.listeners[type] = handler;
      }
      close() {
        this.closed = true;
      }
    }
    FakeEventSource.instances = [];
    const callbacks = [];
    const timers = [];
    const stream = new EventStream({
      EventSourceImpl: FakeEventSource,
      setTimeoutImpl: (callback, delay) => {
        timers.push({ callback, delay });
        return timers.length;
      },
      clearTimeoutImpl: vi.fn(),
    });

    stream.start({ onConnection: (status) => callbacks.push(status) });
    const source = FakeEventSource.instances[0];
    expect(source.url).toBe("/api/v1/events");
    expect(source.options).toEqual({ withCredentials: true });
    source.onopen();
    source.onerror();
    expect(callbacks).toEqual(["connected", "reconnecting"]);
    expect(timers[0].delay).toBe(1_000);
    timers[0].callback();
    expect(FakeEventSource.instances).toHaveLength(2);
    stream.stop();
  });
});

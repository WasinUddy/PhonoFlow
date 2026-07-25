// @vitest-environment happy-dom
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { createFixtureState, spectrumColumn } from "../fixtures/state.js";

const harness = vi.hoisted(() => ({
  api: null,
  apiInstances: [],
  streams: [],
  ApiProblem: null,
}));

vi.mock("../../src/api.js", () => {
  class ApiProblem extends Error {
    constructor(problem = {}, response = {}) {
      const title = String(problem.title ?? `Request failed (${response.status ?? "network"})`);
      const detail = String(problem.detail ?? "");
      super(detail ? `${title}: ${detail}` : title);
      this.name = "ApiProblem";
      this.title = title;
      this.detail = detail;
      this.status = Number(problem.status ?? response.status ?? 0);
    }
  }

  class PhonoFlowAPI {
    constructor() {
      harness.apiInstances.push(this);
    }

    getState(...args) {
      return harness.api.getState(...args);
    }

    pair(...args) {
      return harness.api.pair(...args);
    }

    logout(...args) {
      return harness.api.logout(...args);
    }

    refreshDevices(...args) {
      return harness.api.refreshDevices(...args);
    }

    updateSelection(...args) {
      return harness.api.updateSelection(...args);
    }

    updateMonitor(...args) {
      return harness.api.updateMonitor(...args);
    }

    updateRadio(...args) {
      return harness.api.updateRadio(...args);
    }

    updateRecording(...args) {
      return harness.api.updateRecording(...args);
    }

    updateProcessing(...args) {
      return harness.api.updateProcessing(...args);
    }

    updateEqualizer(...args) {
      return harness.api.updateEqualizer(...args);
    }
  }

  class EventStream {
    constructor() {
      this.handlers = {};
      this.start = vi.fn((handlers) => {
        this.handlers = handlers;
      });
      this.stop = vi.fn();
      harness.streams.push(this);
    }
  }

  harness.ApiProblem = ApiProblem;
  return { ApiProblem, EventStream, PhonoFlowAPI };
});

const html = readFileSync(resolve(process.cwd(), "index.html"), "utf8")
  .replace(/<link[^>]+rel="stylesheet"[^>]*>/g, "")
  .replace(/<script[^>]*>[\s\S]*?<\/script>/g, "");

const nextTask = () => new Promise((resolveTask) => setTimeout(resolveTask, 0));

function makeProblem(status, title = "Request rejected", detail = "") {
  return new harness.ApiProblem({ status, title, detail }, { status });
}

function dispatch(element, type) {
  element.dispatchEvent(new Event(type, { bubbles: true, cancelable: true }));
}

function stateAtRevision(revision, update = () => {}) {
  const result = createFixtureState();
  result.revision = revision;
  update(result);
  return result;
}

async function loadApplication() {
  await import("../../src/app.js");
  await vi.waitFor(() => {
    expect(harness.api.getState).toHaveBeenCalled();
  });
  await nextTask();
}

async function loadAuthenticatedApplication() {
  await loadApplication();
  await vi.waitFor(() => {
    expect(document.getElementById("dashboard-view").hidden).toBe(false);
    expect(harness.streams.at(-1)?.start).toHaveBeenCalledOnce();
  });
  return harness.streams.at(-1);
}

async function waitForCall(mock, count = 1) {
  await vi.waitFor(() => expect(mock).toHaveBeenCalledTimes(count));
  await nextTask();
}

describe("WebUI application controller", () => {
  beforeEach(() => {
    vi.resetModules();
    document.open();
    document.write(html);
    document.close();

    HTMLCanvasElement.prototype.getContext = () => null;
    HTMLMediaElement.prototype.load = vi.fn();
    HTMLMediaElement.prototype.pause = vi.fn();
    HTMLMediaElement.prototype.play = vi.fn().mockResolvedValue(undefined);
    globalThis.requestAnimationFrame = vi.fn();

    const snapshot = createFixtureState();
    harness.apiInstances = [];
    harness.streams = [];
    harness.api = {
      getState: vi.fn().mockResolvedValue(snapshot),
      pair: vi.fn().mockResolvedValue({ paired: true }),
      logout: vi.fn().mockResolvedValue(null),
      refreshDevices: vi.fn().mockResolvedValue(snapshot),
      updateSelection: vi.fn().mockResolvedValue(snapshot),
      updateMonitor: vi.fn().mockResolvedValue(snapshot),
      updateRadio: vi.fn().mockResolvedValue(snapshot),
      updateRecording: vi.fn().mockResolvedValue(snapshot),
      updateProcessing: vi.fn().mockResolvedValue(snapshot),
      updateEqualizer: vi.fn().mockResolvedValue(snapshot),
    };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("bootstraps, consumes every supported event, and refreshes after reconnect", async () => {
    const stream = await loadAuthenticatedApplication();

    expect(document.getElementById("connection-label").textContent).toBe("Connected");
    expect(document.getElementById("engine-state").textContent).toBe("Running");

    stream.handlers.onEvent({
      type: "meters",
      payload: { sequence: 2, leftDB: -6, rightDB: -12 },
    });
    expect(document.getElementById("left-meter-value").textContent).toBe("−6.0 dB");

    stream.handlers.onEvent({
      type: "meter",
      payload: { sequence: 3, leftDB: -9, rightDB: -15 },
    });
    expect(document.getElementById("left-meter-value").textContent).toBe("−9.0 dB");

    stream.handlers.onEvent({ type: "spectrogram", payload: spectrumColumn });
    expect(document.getElementById("spectrum-summary").textContent).toContain("Peak");
    stream.handlers.onEvent({
      type: "spectrum",
      payload: { sequence: 2, column: Array(64).fill(120) },
    });
    stream.handlers.onEvent({
      type: "spectrogram",
      payload: { sequence: 3, intensities: [1, 2] },
    });

    stream.handlers.onEvent({
      type: "state",
      payload: { revision: 2, monitor: { enabled: true } },
    });
    expect(document.getElementById("monitor-toggle").getAttribute("aria-checked")).toBe("true");
    stream.handlers.onEvent({
      type: "snapshot",
      payload: stateAtRevision(3, (state) => {
        state.radio.enabled = true;
      }),
    });
    expect(document.getElementById("radio-toggle").getAttribute("aria-checked")).toBe("true");

    stream.handlers.onEvent({
      type: "problem",
      payload: { status: 503, title: "Engine unavailable", detail: "Reconnect the interface." },
    });
    expect(document.getElementById("error-title").textContent).toBe("Engine unavailable");
    stream.handlers.onEvent({ type: "future-event", payload: {} });

    let resolveVerification;
    harness.api.getState.mockImplementationOnce(() => new Promise((resolve) => {
      resolveVerification = resolve;
    }));
    stream.handlers.onConnection("reconnecting");
    stream.handlers.onConnection("reconnecting");
    expect(harness.api.getState).toHaveBeenCalledTimes(2);
    resolveVerification(stateAtRevision(4));
    await nextTask();

    harness.api.getState.mockResolvedValueOnce(stateAtRevision(1));
    stream.handlers.onConnection("connected");
    await waitForCall(harness.api.getState, 3);
    expect(document.getElementById("state-revision").textContent).toBe("1");

    window.dispatchEvent(new Event("beforeunload"));
    expect(stream.stop).toHaveBeenCalled();
  });

  it("validates, sanitizes, and submits pairing codes with actionable errors", async () => {
    harness.api.getState
      .mockRejectedValueOnce(makeProblem(401, "Pairing required"))
      .mockResolvedValueOnce(createFixtureState());
    await loadApplication();

    const code = document.getElementById("pairing-code");
    const form = document.getElementById("pairing-form");
    expect(document.getElementById("pairing-view").hidden).toBe(false);

    code.value = "12a34-56789";
    dispatch(code, "input");
    expect(code.value).toBe("123456");

    code.value = "123";
    dispatch(form, "submit");
    expect(document.getElementById("pairing-error").textContent).toContain("all six digits");
    expect(document.activeElement).toBe(code);

    code.value = "123x";
    dispatch(code, "input");
    expect(document.getElementById("pairing-error").textContent).toBe("");

    code.value = "123456";
    dispatch(form, "submit");
    await waitForCall(harness.api.pair);
    await vi.waitFor(() => {
      expect(document.getElementById("dashboard-view").hidden).toBe(false);
      expect(harness.streams.at(-1)?.start).toHaveBeenCalledOnce();
    });
    expect(code.value).toBe("");
  });

  it.each([
    [429, "", "Too many attempts"],
    [422, "The code expired.", "The code expired."],
    [403, "", "invalid or expired"],
  ])("explains pairing failure status %i", async (status, detail, expected) => {
    harness.api.getState.mockRejectedValueOnce(makeProblem(401, "Pairing required"));
    harness.api.pair.mockRejectedValueOnce(makeProblem(status, "Pairing failed", detail));
    await loadApplication();

    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");

    await waitForCall(harness.api.pair);
    expect(document.getElementById("pairing-error").textContent).toContain(expected);
  });

  it("uses the server message for an unexpected pairing failure", async () => {
    harness.api.getState.mockRejectedValueOnce(makeProblem(401, "Pairing required"));
    harness.api.pair.mockRejectedValueOnce(new Error("The LAN connection disappeared."));
    await loadApplication();

    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");
    await waitForCall(harness.api.pair);

    expect(document.getElementById("pairing-error").textContent)
      .toBe("The LAN connection disappeared.");
  });

  it("routes every dashboard control through an idempotent API mutation", async () => {
    await loadAuthenticatedApplication();

    const inputDevice = document.getElementById("input-device");
    inputDevice.value = "macbook-mic";
    dispatch(inputDevice, "change");
    await waitForCall(harness.api.updateSelection);
    expect(harness.api.updateSelection).toHaveBeenLastCalledWith({
      inputUID: "macbook-mic",
      inputRouteID: "mono",
      outputUID: "built-in-output",
    });

    dispatch(document.getElementById("input-route"), "change");
    await waitForCall(harness.api.updateSelection, 2);
    dispatch(document.getElementById("output-device"), "change");
    await waitForCall(harness.api.updateSelection, 3);

    dispatch(document.getElementById("monitor-toggle"), "click");
    await waitForCall(harness.api.updateMonitor);
    expect(harness.api.updateMonitor).toHaveBeenCalledWith(true);
    dispatch(document.getElementById("radio-toggle"), "click");
    await waitForCall(harness.api.updateRadio);
    expect(harness.api.updateRadio).toHaveBeenCalledWith(true);
    dispatch(document.getElementById("recording-toggle"), "click");
    await waitForCall(harness.api.updateRecording);
    expect(harness.api.updateRecording).toHaveBeenCalledWith(true);

    const gain = document.getElementById("gain-control");
    gain.value = "6";
    dispatch(gain, "input");
    expect(document.getElementById("gain-output").textContent).toBe("+6.0 dB");
    expect(gain.getAttribute("aria-valuetext")).toBe("plus 6 decibels");
    dispatch(gain, "change");
    await waitForCall(harness.api.updateProcessing);
    expect(harness.api.updateProcessing.mock.calls[0][0].gain).toBeCloseTo(1.995, 2);

    dispatch(document.getElementById("auto-gain-toggle"), "click");
    await waitForCall(harness.api.updateProcessing, 2);
    expect(harness.api.updateProcessing).toHaveBeenLastCalledWith({
      autoGainEnabled: true,
    });

    const eq = document.getElementById("eq-band-5");
    eq.value = "-3";
    dispatch(eq, "input");
    expect(document.querySelector('output[for="eq-band-5"]').textContent).toBe("−3.0 dB");
    expect(eq.getAttribute("aria-valuetext")).toBe("minus 3 decibels");
    dispatch(eq, "change");
    await waitForCall(harness.api.updateEqualizer);
    expect(harness.api.updateEqualizer.mock.calls[0][0][5].gainDB).toBe(-3);

    dispatch(document.getElementById("reset-eq"), "click");
    await waitForCall(harness.api.updateEqualizer, 2);
    expect(harness.api.updateEqualizer.mock.calls[1][0].every(({ gainDB }) => gainDB === 0))
      .toBe(true);

    dispatch(document.getElementById("refresh-devices"), "click");
    await waitForCall(harness.api.refreshDevices);

    const spectrumToggle = document.getElementById("spectrum-toggle");
    dispatch(spectrumToggle, "click");
    expect(spectrumToggle.textContent).toBe("Resume");
    expect(document.getElementById("announcer").textContent).toBe("Spectrogram paused.");
    dispatch(spectrumToggle, "click");
    expect(spectrumToggle.textContent).toBe("Pause");
    expect(document.getElementById("announcer").textContent).toBe("Spectrogram resumed.");

    dispatch(document.getElementById("prepare-audio"), "click");
    await nextTask();
    expect(HTMLMediaElement.prototype.play).toHaveBeenCalled();
    expect(document.getElementById("live-audio").getAttribute("src")).toBe("/audio/live.wav");

    dispatch(document.getElementById("live-audio"), "error");
    expect(document.getElementById("error-title").textContent)
      .toBe("Browser playback unavailable");
    dispatch(document.getElementById("dismiss-error"), "click");
    expect(document.getElementById("error-notice").hidden).toBe(true);
  });

  it("suppresses a duplicate pending command and refreshes an empty response", async () => {
    await loadAuthenticatedApplication();

    let resolveMonitor;
    harness.api.updateMonitor.mockImplementationOnce(() => new Promise((resolve) => {
      resolveMonitor = resolve;
    }));
    const monitor = document.getElementById("monitor-toggle");
    dispatch(monitor, "click");
    dispatch(monitor, "click");
    expect(harness.api.updateMonitor).toHaveBeenCalledOnce();
    resolveMonitor({ accepted: true });
    await vi.waitFor(() => expect(harness.api.getState).toHaveBeenCalledTimes(2));

    expect(document.getElementById("monitor-toggle").disabled).toBe(false);
  });

  it("reconciles conflicts and reports both API and network mutation failures", async () => {
    await loadAuthenticatedApplication();

    harness.api.updateSelection.mockRejectedValueOnce(
      makeProblem(409, "Recording in progress", "Stop recording first."),
    );
    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    dispatch(document.getElementById("input-route"), "change");
    await waitForCall(harness.api.updateSelection);
    await vi.waitFor(() => expect(harness.api.getState).toHaveBeenCalledTimes(2));
    expect(document.getElementById("error-title").textContent).toBe("Recording in progress");
    expect(document.getElementById("error-detail").textContent).toBe("Stop recording first.");

    harness.api.updateRadio.mockRejectedValueOnce(Object.assign(
      new Error("No route to host"),
      { name: "NetworkError" },
    ));
    dispatch(document.getElementById("radio-toggle"), "click");
    await waitForCall(harness.api.updateRadio);
    expect(document.getElementById("error-title").textContent).toBe("Connection unavailable");

    harness.api.updateRecording.mockRejectedValueOnce(makeProblem(503, "Engine stopped"));
    dispatch(document.getElementById("recording-toggle"), "click");
    await waitForCall(harness.api.updateRecording);
    expect(document.getElementById("error-detail").textContent)
      .toBe("The Mac rejected this request.");
  });

  it("returns to pairing after an unauthorized mutation or event", async () => {
    const stream = await loadAuthenticatedApplication();

    harness.api.updateMonitor.mockRejectedValueOnce(makeProblem(401, "Pairing required"));
    dispatch(document.getElementById("monitor-toggle"), "click");
    await waitForCall(harness.api.updateMonitor);
    expect(document.getElementById("pairing-view").hidden).toBe(false);
    expect(stream.stop).toHaveBeenCalled();
    expect(HTMLMediaElement.prototype.pause).toHaveBeenCalled();

    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");
    await waitForCall(harness.api.pair);
    await vi.waitFor(() => expect(document.getElementById("dashboard-view").hidden).toBe(false));

    harness.streams.at(-1).handlers.onEvent({
      type: "problem",
      payload: { status: 401, title: "Session expired" },
    });
    expect(document.getElementById("pairing-error").textContent).toContain("session ended");
  });

  it("handles logout success, accepted expiry, and a rejected logout", async () => {
    await loadAuthenticatedApplication();

    dispatch(document.getElementById("logout-button"), "click");
    await waitForCall(harness.api.logout);
    expect(document.getElementById("pairing-error").textContent).toContain("Logged out");

    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");
    await waitForCall(harness.api.pair);
    await vi.waitFor(() => expect(document.getElementById("dashboard-view").hidden).toBe(false));

    harness.api.logout.mockRejectedValueOnce(makeProblem(401, "Already logged out"));
    dispatch(document.getElementById("logout-button"), "click");
    await waitForCall(harness.api.logout, 2);
    expect(document.getElementById("pairing-view").hidden).toBe(false);

    harness.api.getState.mockResolvedValueOnce(stateAtRevision(3));
    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");
    await waitForCall(harness.api.pair, 2);
    await vi.waitFor(() => expect(document.getElementById("dashboard-view").hidden).toBe(false));

    harness.api.logout.mockRejectedValueOnce(new Error("Logout transport failed."));
    dispatch(document.getElementById("logout-button"), "click");
    await waitForCall(harness.api.logout, 3);
    expect(document.getElementById("error-title").textContent).toBe("Request failed");
    expect(document.getElementById("dashboard-view").hidden).toBe(false);
  });

  it("shows bootstrap errors and tolerates failed reconnect verification", async () => {
    harness.api.getState.mockRejectedValueOnce(Object.assign(
      new Error("The service is offline."),
      { name: "NetworkError" },
    ));
    await loadApplication();
    expect(document.getElementById("connection-label").textContent).toBe("Disconnected");
    expect(document.getElementById("error-title").textContent).toBe("Connection unavailable");

    vi.resetModules();
    document.open();
    document.write(html);
    document.close();
    harness.streams = [];
    harness.api.getState
      .mockReset()
      .mockResolvedValueOnce(createFixtureState())
      .mockRejectedValueOnce(makeProblem(401, "Session expired"));
    const stream = await loadAuthenticatedApplication();
    stream.handlers.onConnection("reconnecting");
    await vi.waitFor(() => expect(document.getElementById("pairing-view").hidden).toBe(false));
  });

  it("expires the session when a reconnect baseline is unauthorized", async () => {
    const stream = await loadAuthenticatedApplication();

    stream.handlers.onConnection("disconnected");
    harness.api.getState.mockRejectedValueOnce(makeProblem(401, "Session expired"));
    stream.handlers.onConnection("connected");

    await vi.waitFor(() => {
      expect(document.getElementById("pairing-view").hidden).toBe(false);
      expect(stream.stop).toHaveBeenCalled();
    });
  });

  it("keeps the original conflict when reconciliation fails and announces blocked playback", async () => {
    await loadAuthenticatedApplication();

    harness.api.updateSelection.mockRejectedValueOnce(
      makeProblem(409, "Selection locked", "Stop recording."),
    );
    harness.api.getState.mockRejectedValueOnce(new Error("Refresh failed."));
    dispatch(document.getElementById("input-route"), "change");
    await waitForCall(harness.api.updateSelection);
    expect(document.getElementById("error-title").textContent).toBe("Selection locked");

    HTMLMediaElement.prototype.play.mockRejectedValueOnce(new Error("Gesture required."));
    dispatch(document.getElementById("prepare-audio"), "click");
    await nextTask();
    expect(document.getElementById("announcer").textContent)
      .toBe("Live audio is ready. Use the audio play control to begin.");
  });
});

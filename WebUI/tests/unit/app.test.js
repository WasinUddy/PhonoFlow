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
  players: [],
  streams: [],
  ApiProblem: null,
  windowListeners: [],
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

vi.mock("../../src/live-audio.js", () => {
  class LiveAudioPlayer {
    constructor(callbacks = {}) {
      this.callbacks = callbacks;
      this.state = "stopped";
      this.stats = {
        contextState: "closed",
        receivedFrames: 0,
        scheduledFrames: 0,
        playedFrames: 0,
        activeSources: 0,
      };
      this.start = vi.fn(async () => {
        this.state = "starting";
        this.callbacks.onState?.(this.snapshot());
        this.state = "playing";
        this.stats = {
          contextState: "running",
          receivedFrames: 2_400,
          scheduledFrames: 2_400,
          playedFrames: 2_400,
          activeSources: 1,
        };
        const snapshot = this.snapshot();
        this.callbacks.onState?.(snapshot);
        return snapshot;
      });
      this.stop = vi.fn(async () => {
        this.state = "stopped";
        this.stats = {
          contextState: "closed",
          receivedFrames: 0,
          scheduledFrames: 0,
          playedFrames: 0,
          activeSources: 0,
        };
        const snapshot = this.snapshot();
        this.callbacks.onState?.(snapshot);
        return snapshot;
      });
      harness.players.push(this);
    }

    get active() {
      return ["starting", "playing", "reconnecting"].includes(this.state);
    }

    snapshot() {
      return { state: this.state, ...this.stats };
    }

    fail(error) {
      this.state = "failed";
      this.callbacks.onState?.(this.snapshot());
      this.callbacks.onError?.(error);
    }

    expireSession() {
      this.callbacks.onUnauthorized?.();
    }
  }

  return { LiveAudioPlayer };
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

function pageTransition(type, persisted) {
  const event = new Event(type);
  Object.defineProperty(event, "persisted", { value: persisted });
  return event;
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
    harness.windowListeners = [];
    const addEventListener = window.addEventListener.bind(window);
    vi.spyOn(window, "addEventListener").mockImplementation((...arguments_) => {
      harness.windowListeners.push(arguments_);
      return addEventListener(...arguments_);
    });

    const snapshot = createFixtureState();
    harness.apiInstances = [];
    harness.players = [];
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
    for (const [type, listener, options] of harness.windowListeners) {
      window.removeEventListener(type, listener, options);
    }
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

    window.dispatchEvent(pageTransition("pagehide", false));
    expect(stream.stop).toHaveBeenCalled();
  });

  it("stops for pagehide and restores one fresh SSE session from BFCache", async () => {
    const stream = await loadAuthenticatedApplication();
    const player = harness.players.at(-1);
    dispatch(document.getElementById("prepare-audio"), "click");
    await waitForCall(player.start);

    window.dispatchEvent(pageTransition("pagehide", true));
    window.dispatchEvent(pageTransition("pagehide", true));
    expect(stream.stop).toHaveBeenCalledOnce();
    expect(player.stop).toHaveBeenCalledOnce();

    window.dispatchEvent(pageTransition("pageshow", false));
    expect(harness.api.getState).toHaveBeenCalledOnce();

    harness.api.getState.mockResolvedValueOnce(stateAtRevision(1));
    window.dispatchEvent(pageTransition("pageshow", true));
    await waitForCall(harness.api.getState, 2);
    await vi.waitFor(() => expect(stream.start).toHaveBeenCalledTimes(2));
    expect(document.getElementById("state-revision").textContent).toBe("1");
    expect(player.start).toHaveBeenCalledOnce();

    window.dispatchEvent(pageTransition("pageshow", true));
    expect(harness.api.getState).toHaveBeenCalledTimes(2);
    expect(stream.start).toHaveBeenCalledTimes(2);

    window.dispatchEvent(pageTransition("pagehide", true));
    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    window.dispatchEvent(pageTransition("pageshow", true));
    await waitForCall(harness.api.getState, 3);
    await vi.waitFor(() => expect(stream.start).toHaveBeenCalledTimes(3));
    expect(stream.stop).toHaveBeenCalledTimes(2);
    expect(player.stop).toHaveBeenCalledTimes(2);
    expect(player.start).toHaveBeenCalledOnce();
  });

  it("does not announce a stale stop after an immediate playback restart", async () => {
    await loadAuthenticatedApplication();
    const player = harness.players.at(-1);
    dispatch(document.getElementById("prepare-audio"), "click");
    await waitForCall(player.start);

    let finishStop;
    player.stop.mockImplementationOnce(() => {
      player.state = "stopped";
      player.stats = {
        contextState: "closed",
        receivedFrames: 0,
        scheduledFrames: 0,
        playedFrames: 0,
        activeSources: 0,
      };
      const snapshot = player.snapshot();
      player.callbacks.onState?.(snapshot);
      return new Promise((resolve) => {
        finishStop = () => resolve(snapshot);
      });
    });

    dispatch(document.getElementById("prepare-audio"), "click");
    expect(document.getElementById("prepare-audio").textContent)
      .toBe("Start browser listening");
    dispatch(document.getElementById("prepare-audio"), "click");
    await waitForCall(player.start, 2);
    expect(document.getElementById("announcer").textContent)
      .toBe("Browser listening started.");

    finishStop();
    await nextTask();
    expect(document.getElementById("announcer").textContent)
      .toBe("Browser listening started.");
  });

  it("returns to pairing when BFCache restoration is unauthorized", async () => {
    const stream = await loadAuthenticatedApplication();
    window.dispatchEvent(pageTransition("pagehide", true));
    harness.api.getState.mockRejectedValueOnce(makeProblem(401, "Session expired"));
    window.dispatchEvent(pageTransition("pageshow", true));

    await vi.waitFor(() => {
      expect(document.getElementById("pairing-view").hidden).toBe(false);
    });
    expect(stream.start).toHaveBeenCalledOnce();
    expect(stream.stop).toHaveBeenCalledTimes(2);
  });

  it("does not let a pre-pagehide bootstrap reopen the event stream", async () => {
    let resolveBootstrap;
    harness.api.getState.mockImplementationOnce(() => new Promise((resolve) => {
      resolveBootstrap = resolve;
    }));
    const application = import("../../src/app.js");
    await vi.waitFor(() => expect(harness.api.getState).toHaveBeenCalledOnce());

    window.dispatchEvent(pageTransition("pagehide", true));
    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    window.dispatchEvent(pageTransition("pageshow", true));
    resolveBootstrap(stateAtRevision(99));
    await application;

    await waitForCall(harness.api.getState, 2);
    const stream = harness.streams.at(-1);
    await vi.waitFor(() => expect(stream.start).toHaveBeenCalledOnce());
    expect(document.getElementById("state-revision").textContent).toBe("2");
  });

  it("does not let a pre-pagehide mutation affect a restored mutation", async () => {
    await loadAuthenticatedApplication();
    let rejectOldMutation;
    let resolveNewMutation;
    harness.api.updateMonitor
      .mockImplementationOnce(() => new Promise((_resolve, reject) => {
        rejectOldMutation = reject;
      }))
      .mockImplementationOnce(() => new Promise((resolve) => {
        resolveNewMutation = resolve;
      }));

    const monitor = document.getElementById("monitor-toggle");
    dispatch(monitor, "click");
    await waitForCall(harness.api.updateMonitor);
    expect(monitor.disabled).toBe(true);

    window.dispatchEvent(pageTransition("pagehide", true));
    harness.api.getState.mockResolvedValueOnce(stateAtRevision(2));
    window.dispatchEvent(pageTransition("pageshow", true));
    await waitForCall(harness.api.getState, 2);
    await vi.waitFor(() => expect(monitor.disabled).toBe(false));

    dispatch(monitor, "click");
    await waitForCall(harness.api.updateMonitor, 2);
    expect(monitor.disabled).toBe(true);

    rejectOldMutation(makeProblem(401, "Expired pre-hide session"));
    await nextTask();
    expect(document.getElementById("dashboard-view").hidden).toBe(false);
    expect(monitor.disabled).toBe(true);

    resolveNewMutation(stateAtRevision(3, (next) => {
      next.monitor.enabled = true;
    }));
    await vi.waitFor(() => expect(monitor.disabled).toBe(false));
    expect(monitor.getAttribute("aria-checked")).toBe("true");
  });

  it("clears pre-pagehide pending controls even when restoration fails", async () => {
    const stream = await loadAuthenticatedApplication();
    let rejectMutation;
    harness.api.updateMonitor.mockImplementationOnce(() => new Promise((_resolve, reject) => {
      rejectMutation = reject;
    }));

    const monitor = document.getElementById("monitor-toggle");
    dispatch(monitor, "click");
    await waitForCall(harness.api.updateMonitor);
    expect(monitor.disabled).toBe(true);

    window.dispatchEvent(pageTransition("pagehide", true));
    expect(monitor.disabled).toBe(false);
    harness.api.getState.mockRejectedValueOnce(new Error("Restore unavailable."));
    window.dispatchEvent(pageTransition("pageshow", true));

    await vi.waitFor(() => {
      expect(document.getElementById("error-detail").textContent)
        .toContain("Restore unavailable.");
    });
    expect(monitor.disabled).toBe(false);
    expect(stream.start).toHaveBeenCalledTimes(2);
    rejectMutation(makeProblem(401, "Expired pre-hide mutation"));
    await nextTask();
    expect(document.getElementById("dashboard-view").hidden).toBe(false);
    expect(monitor.disabled).toBe(false);
  });

  it("invalidates in-flight mutations when authentication is revoked", async () => {
    const stream = await loadAuthenticatedApplication();
    let resolveMutation;
    harness.api.updateMonitor.mockImplementationOnce(() => new Promise((resolve) => {
      resolveMutation = resolve;
    }));

    dispatch(document.getElementById("monitor-toggle"), "click");
    await waitForCall(harness.api.updateMonitor);
    stream.handlers.onEvent({
      type: "problem",
      payload: { status: 401, title: "Session expired" },
    });
    expect(document.getElementById("pairing-view").hidden).toBe(false);

    resolveMutation(stateAtRevision(99, (next) => {
      next.monitor.enabled = true;
    }));
    await nextTask();
    expect(document.getElementById("pairing-view").hidden).toBe(false);
    expect(document.getElementById("dashboard-view").hidden).toBe(true);
  });

  it("invalidates a pairing completion across page lifecycle restoration", async () => {
    harness.api.getState
      .mockReset()
      .mockRejectedValueOnce(makeProblem(401, "Pairing required"))
      .mockRejectedValueOnce(new Error("Restore unavailable."));
    let resolvePairing;
    harness.api.pair.mockImplementationOnce(() => new Promise((resolve) => {
      resolvePairing = resolve;
    }));
    await loadApplication();

    document.getElementById("pairing-code").value = "123456";
    dispatch(document.getElementById("pairing-form"), "submit");
    await waitForCall(harness.api.pair);
    expect(document.getElementById("pair-button").disabled).toBe(true);

    window.dispatchEvent(pageTransition("pagehide", true));
    expect(document.getElementById("pair-button").disabled).toBe(false);
    window.dispatchEvent(pageTransition("pageshow", true));
    await waitForCall(harness.api.getState, 2);
    await vi.waitFor(() => {
      expect(document.getElementById("error-detail").textContent)
        .toContain("Restore unavailable.");
    });

    resolvePairing({ paired: true });
    await nextTask();
    expect(harness.api.getState).toHaveBeenCalledTimes(2);
    expect(document.getElementById("pairing-view").hidden).toBe(false);
    expect(document.getElementById("pair-button").disabled).toBe(false);
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
    await waitForCall(harness.players.at(-1).start);
    expect(document.getElementById("prepare-audio").textContent)
      .toBe("Stop browser listening");
    expect(document.getElementById("live-audio").dataset).toMatchObject({
      playbackState: "playing",
      contextState: "running",
      scheduledFrames: "2400",
      playedFrames: "2400",
    });
    expect(document.getElementById("announcer").textContent)
      .toBe("Browser listening started.");

    harness.players.at(-1).fail(new Error("The live audio stream failed."));
    expect(document.getElementById("error-title").textContent)
      .toBe("Browser playback unavailable");
    expect(document.getElementById("error-detail").textContent)
      .toBe("The live audio stream failed.");
    dispatch(document.getElementById("dismiss-error"), "click");
    expect(document.getElementById("error-notice").hidden).toBe(true);

    dispatch(document.getElementById("prepare-audio"), "click");
    await waitForCall(harness.players.at(-1).start, 2);
    dispatch(document.getElementById("prepare-audio"), "click");
    await waitForCall(harness.players.at(-1).stop);
    expect(document.getElementById("live-audio").hidden).toBe(true);
    expect(document.getElementById("announcer").textContent)
      .toBe("Browser listening stopped.");
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
    expect(harness.players.at(-1).stop).toHaveBeenCalled();

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

  it("keeps the original conflict when reconciliation fails and ignores cancelled playback", async () => {
    await loadAuthenticatedApplication();

    harness.api.updateSelection.mockRejectedValueOnce(
      makeProblem(409, "Selection locked", "Stop recording."),
    );
    harness.api.getState.mockRejectedValueOnce(new Error("Refresh failed."));
    dispatch(document.getElementById("input-route"), "change");
    await waitForCall(harness.api.updateSelection);
    expect(document.getElementById("error-title").textContent).toBe("Selection locked");

    harness.players.at(-1).start.mockRejectedValueOnce(
      Object.assign(new Error("Stopped."), { name: "AbortError" }),
    );
    dispatch(document.getElementById("prepare-audio"), "click");
    await nextTask();
    expect(document.getElementById("error-title").textContent).toBe("Selection locked");
  });
});

// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createInitialState, reducer } from "../../src/state.js";
import { DashboardView } from "../../src/view.js";
import { createFixtureState } from "../fixtures/state.js";

const htmlPath = resolve(process.cwd(), "index.html");
const html = readFileSync(htmlPath, "utf8")
  .replace(/<link[^>]+rel="stylesheet"[^>]*>/g, "")
  .replace(/<script[^>]*>[\s\S]*?<\/script>/g, "");

describe("dashboard rendering", () => {
  let view;
  let state;

  beforeEach(() => {
    document.open();
    document.write(html);
    document.close();
    HTMLCanvasElement.prototype.getContext = () => null;
    view = new DashboardView(document);
    state = reducer(createInitialState(), {
      type: "SNAPSHOT",
      payload: createFixtureState(),
    });
    view.render(state);
  });

  it("switches from pairing to an authoritative dashboard", () => {
    expect(document.getElementById("pairing-view").hidden).toBe(true);
    expect(document.getElementById("dashboard-view").hidden).toBe(false);
    expect(document.getElementById("engine-state").textContent).toBe("Running");
    expect(document.getElementById("engine-format").textContent).toContain("48 kHz");
  });

  it("renders stable UID and route selections without unsafe markup", () => {
    const hostile = createFixtureState();
    hostile.revision = 2;
    hostile.devices[0].name = '<img src=x onerror="window.pwned=true">';
    const hostileState = reducer(state, { type: "STATE_PATCH", payload: hostile });
    view.render(hostileState);

    const input = document.getElementById("input-device");
    expect(input.value).toBe("focusrite-scarlett-2i2");
    expect(input.selectedOptions[0].textContent).toContain("<img");
    expect(input.querySelector("img")).toBeNull();
    expect(document.getElementById("input-route").value).toBe("channels-1-2");
  });

  it("keeps high-rate updates local and preserves keyboard focus", () => {
    const gain = document.getElementById("gain-control");
    gain.focus();
    const inputBefore = document.getElementById("input-device");
    const metered = reducer(state, {
      type: "METERS",
      payload: { sequence: 1, leftDB: -6, rightDB: -12 },
    });
    view.render(metered, { type: "METERS" });

    expect(document.activeElement).toBe(gain);
    expect(document.getElementById("input-device")).toBe(inputBefore);
    expect(document.getElementById("left-meter-value").textContent).toBe("−6.0 dB");
    expect(document.getElementById("left-meter").getAttribute("aria-valuetext")).toBe("−6.0 dB");
  });

  it("locks input routing while recording but leaves output available", () => {
    const recording = reducer(state, {
      type: "STATE_PATCH",
      payload: { revision: 2, recording: { enabled: true, durationSeconds: 9 } },
    });
    view.render(recording);

    expect(document.getElementById("input-device").disabled).toBe(true);
    expect(document.getElementById("input-route").disabled).toBe(true);
    expect(document.getElementById("output-device").disabled).toBe(false);
    expect(document.getElementById("recording-info").textContent).toContain("0:09");
  });

  it("creates ten labelled native range inputs", () => {
    const controls = [...document.querySelectorAll("#eq-controls input[type=range]")];
    expect(controls).toHaveLength(10);
    expect(controls[0].getAttribute("aria-label")).toBe("31 hertz gain");
    expect(controls[9].getAttribute("aria-label")).toBe("16,000 hertz gain");
    expect(controls.every((control) => control.getAttribute("aria-valuetext") === "0 decibels")).toBe(true);
  });

  it("updates playback telemetry without repeating live-status text mutations", () => {
    view.renderAudioPlayer({
      state: "playing",
      contextState: "running",
      receivedFrames: 2_400,
      scheduledFrames: 2_400,
      playedFrames: 2_400,
      activeSources: 1,
    });

    const status = document.getElementById("live-audio");
    const title = document.getElementById("live-audio-title");
    const detail = document.getElementById("live-audio-detail");
    const titleNode = title.firstChild;
    const detailNode = detail.firstChild;

    view.renderAudioPlayer({
      state: "playing",
      contextState: "running",
      receivedFrames: 4_800,
      scheduledFrames: 4_800,
      playedFrames: 4_200,
      activeSources: 2,
    });

    expect(title.firstChild).toBe(titleNode);
    expect(detail.firstChild).toBe(detailNode);
    expect(status.dataset).toMatchObject({
      playbackState: "playing",
      contextState: "running",
      receivedFrames: "4800",
      scheduledFrames: "4800",
      playedFrames: "4200",
      activeSources: "2",
    });

    view.renderAudioPlayer({ state: "reconnecting", contextState: "suspended" });
    expect(title.firstChild).not.toBe(titleNode);
    expect(detail.firstChild).not.toBe(detailNode);
    expect(title.textContent).toBe("Reconnecting browser audio…");
    expect(detail.textContent).toBe("The Mac stream was interrupted.");
  });

  it("groups the listening control and status in one aligned action area", () => {
    const actions = document.querySelector(".listen-actions");

    expect(actions).not.toBeNull();
    expect([...actions.children]).toEqual([
      document.getElementById("prepare-audio"),
      document.getElementById("live-audio"),
      actions.querySelector(".inline-note"),
    ]);
  });
});

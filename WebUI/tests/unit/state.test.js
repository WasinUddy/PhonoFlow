import { describe, expect, it } from "vitest";
import {
  createInitialState,
  decibelsToLinearGain,
  linearGainToDB,
  normalizeServerState,
  reducer,
} from "../../src/state.js";
import { createFixtureState, spectrumColumn } from "../fixtures/state.js";

describe("state reducer", () => {
  it("applies an authoritative snapshot with stable device routes", () => {
    const state = reducer(createInitialState(), {
      type: "SNAPSHOT",
      payload: createFixtureState(),
    });

    expect(state.authenticated).toBe(true);
    expect(state.revision).toBe(1);
    expect(state.engine.state).toBe("running");
    expect(state.engine.format.bufferFrames).toBe(256);
    expect(state.devices.inputs[0]).toMatchObject({
      uid: "focusrite-scarlett-2i2",
      channelCount: 4,
    });
    expect(state.devices.inputs[0].inputRoutes.map((route) => route.id)).toEqual([
      "channels-1-2",
      "channels-3-4",
    ]);
    expect(state.selection).toEqual({
      inputUID: "focusrite-scarlett-2i2",
      inputRouteID: "channels-1-2",
      outputUID: "built-in-output",
    });
    expect(state.devices.outputs.map((device) => device.uid)).toEqual([
      "focusrite-scarlett-2i2",
      "built-in-output",
    ]);
    expect(state.telemetry).toEqual({ droppedFrames: 0, xruns: 0 });
  });

  it("ignores stale control revisions without discarding the last snapshot", () => {
    const snapshot = createFixtureState();
    snapshot.revision = 10;
    snapshot.monitor.enabled = true;
    const current = reducer(createInitialState(), { type: "SNAPSHOT", payload: snapshot });
    const stale = reducer(current, {
      type: "STATE_PATCH",
      payload: { revision: 9, monitor: { enabled: false } },
    });

    expect(stale).toBe(current);
    expect(stale.monitor.enabled).toBe(true);
  });

  it("merges newer partial state and clears pending controls", () => {
    const current = reducer(
      reducer(createInitialState(), { type: "SNAPSHOT", payload: createFixtureState() }),
      { type: "MUTATION_START", key: "monitor" },
    );
    const next = reducer(current, {
      type: "STATE_PATCH",
      payload: { revision: 2, monitor: { enabled: true } },
    });

    expect(next.monitor.enabled).toBe(true);
    expect(next.pending).toEqual({});
    expect(next.devices).toEqual(current.devices);
  });

  it("accepts a forced baseline after a server restart resets revision", () => {
    const beforeRestart = createFixtureState();
    beforeRestart.revision = 50;
    beforeRestart.monitor.enabled = true;
    const current = reducer(createInitialState(), { type: "SNAPSHOT", payload: beforeRestart });
    const afterRestart = createFixtureState();
    afterRestart.revision = 1;
    afterRestart.monitor.enabled = false;

    const ignored = reducer(current, { type: "SNAPSHOT", payload: afterRestart });
    const restored = reducer(current, { type: "BASELINE", payload: afterRestart });

    expect(ignored).toBe(current);
    expect(restored.revision).toBe(1);
    expect(restored.monitor.enabled).toBe(false);
  });

  it("tracks high-rate sequences independently and drops duplicates", () => {
    const initial = reducer(createInitialState(), {
      type: "SNAPSHOT",
      payload: createFixtureState(),
    });
    const metered = reducer(initial, {
      type: "METERS",
      payload: { sequence: 8, left: 0.5, right: 0.25 },
    });
    const duplicateMeter = reducer(metered, {
      type: "METERS",
      payload: { sequence: 8, left: 1, right: 1 },
    });
    const spectrogram = reducer(duplicateMeter, {
      type: "SPECTROGRAM",
      payload: spectrumColumn,
    });
    const duplicateSpectrum = reducer(spectrogram, {
      type: "SPECTROGRAM",
      payload: { ...spectrumColumn, intensities: Array(64).fill(255) },
    });

    expect(metered.revision).toBe(1);
    expect(metered.meters.leftDB).toBeCloseTo(-6.02, 1);
    expect(duplicateMeter).toBe(metered);
    expect(duplicateSpectrum).toBe(spectrogram);
  });

  it("returns to pairing and clears private state on an expired session", () => {
    const authenticated = reducer(createInitialState(), {
      type: "SNAPSHOT",
      payload: createFixtureState(),
    });
    const expired = reducer(authenticated, {
      type: "AUTH_REQUIRED",
      message: "Session expired.",
    });

    expect(expired.authenticated).toBe(false);
    expect(expired.devices.inputs).toEqual([]);
    expect(expired.pending).toEqual({});
    expect(expired.pairing.error).toBe("Session expired.");
  });

  it("normalizes mono routes, numeric EQ arrays, and linear gain", () => {
    const normalized = normalizeServerState({
      revision: 1,
      devices: {
        inputs: [{ uid: "mono", name: "Mono input", channelCount: 1 }],
        outputs: [],
      },
      processing: { gain: 2 },
      equalizer: { bands: Array(10).fill(3) },
    });

    expect(normalized.devices.inputs[0].inputRoutes[0].channelIndices).toEqual([0, 0]);
    expect(normalized.processing.gainDB).toBeCloseTo(6.02, 1);
    expect(normalized.equalizer.bands.every((band) => band.gainDB === 3)).toBe(true);
    expect(decibelsToLinearGain(linearGainToDB(2))).toBeCloseTo(2);
    expect(decibelsToLinearGain(40)).toBe(4);
    expect(linearGainToDB(0)).toBe(-60);
    expect(decibelsToLinearGain(-60)).toBe(0);
  });
});

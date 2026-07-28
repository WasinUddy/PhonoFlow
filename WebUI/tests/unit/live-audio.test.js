import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import {
  LiveAudioError,
  LiveAudioPlayer,
  StreamingWAVDecoder,
  parseStreamingWAVHeader,
} from "../../src/live-audio.js";

function wavHeader(update = () => {}) {
  const header = new Uint8Array(44);
  const view = new DataView(header.buffer);
  header.set([...Buffer.from("RIFF")], 0);
  view.setUint32(4, 0x7fff_ffff, true);
  header.set([...Buffer.from("WAVE")], 8);
  header.set([...Buffer.from("fmt ")], 12);
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 2, true);
  view.setUint32(24, 48_000, true);
  view.setUint32(28, 192_000, true);
  view.setUint16(32, 4, true);
  view.setUint16(34, 16, true);
  header.set([...Buffer.from("data")], 36);
  view.setUint32(40, 0x7fff_ffdb, true);
  update(view, header);
  return header;
}

function pcm(frames, sample = (frame) => [
  frame % 2 === 0 ? -32_768 : 32_767,
  frame % 3 === 0 ? 16_384 : -16_384,
]) {
  const result = new Uint8Array(frames * 4);
  const view = new DataView(result.buffer);
  for (let frame = 0; frame < frames; frame += 1) {
    const [left, right] = sample(frame);
    view.setInt16(frame * 4, left, true);
    view.setInt16(frame * 4 + 2, right, true);
  }
  return result;
}

function concatenate(...arrays) {
  const result = new Uint8Array(arrays.reduce((size, array) => size + array.byteLength, 0));
  let offset = 0;
  for (const array of arrays) {
    result.set(array, offset);
    offset += array.byteLength;
  }
  return result;
}

class FakeSource {
  constructor({ throwOnCleanup = false } = {}) {
    this.buffer = null;
    this.onended = null;
    this.startedAt = null;
    this.throwOnCleanup = throwOnCleanup;
    this.connect = vi.fn();
    this.disconnect = vi.fn(() => {
      if (this.throwOnCleanup) throw new Error("already disconnected");
    });
    this.stop = vi.fn(() => {
      if (this.throwOnCleanup) throw new Error("already stopped");
    });
  }

  start(time) {
    this.startedAt = time;
  }

  finish() {
    this.onended?.();
  }
}

class FakeContext {
  constructor({ cleanupErrors = false } = {}) {
    this.state = "suspended";
    this.currentTime = 1;
    this.destination = {};
    this.sources = [];
    this.buffers = [];
    this.cleanupErrors = cleanupErrors;
    this.resume = vi.fn(async () => {
      this.state = "running";
    });
    this.close = vi.fn(async () => {
      this.state = "closed";
      if (this.cleanupErrors) throw new Error("already closed");
    });
  }

  createBuffer(channels, frames, sampleRate) {
    const buffer = {
      channels,
      frames,
      sampleRate,
      data: [],
      copyToChannel: vi.fn((samples, channel) => {
        buffer.data[channel] = Float32Array.from(samples);
      }),
    };
    this.buffers.push(buffer);
    return buffer;
  }

  createBufferSource() {
    const source = new FakeSource({ throwOnCleanup: this.cleanupErrors });
    this.sources.push(source);
    return source;
  }
}

function responseWithChunks(chunks, {
  contentType = "audio/wav",
  holdOpen = true,
  ok = true,
  redirected = false,
  status = 200,
  releaseThrows = false,
  cancelThrows = false,
  cancelPromise = null,
} = {}) {
  let index = 0;
  let settleRead;
  const reader = {
    read: vi.fn(() => {
      if (index < chunks.length) {
        const value = chunks[index];
        index += 1;
        return Promise.resolve({ done: false, value });
      }
      if (!holdOpen) return Promise.resolve({ done: true });
      return new Promise((resolve) => {
        settleRead = resolve;
      });
    }),
    cancel: vi.fn(async () => {
      settleRead?.({ done: true });
      await cancelPromise;
      if (cancelThrows) throw new Error("cancel raced");
    }),
    releaseLock: vi.fn(() => {
      if (releaseThrows) throw new Error("released");
    }),
  };
  const body = {
    cancel: vi.fn(async () => {}),
    getReader: () => reader,
  };
  return {
    ok,
    redirected,
    status,
    headers: {
      get: (name) => name.toLowerCase() === "content-type" ? contentType : null,
    },
    body,
    reader,
  };
}

function abortableHold(_milliseconds, signal) {
  return new Promise((_, reject) => {
    signal.addEventListener("abort", () => {
      const error = new Error("stopped");
      error.name = "AbortError";
      reject(error);
    }, { once: true });
  });
}

function playerFixture({
  chunks = [concatenate(wavHeader(), pcm(2_400))],
  context = new FakeContext(),
  fetcher,
  responseOptions,
  ...options
} = {}) {
  const response = responseWithChunks(chunks, responseOptions);
  const effectiveFetcher = fetcher ?? vi.fn(async () => response);
  const states = [];
  const errors = [];
  const unauthorized = [];
  const player = new LiveAudioPlayer({
    fetcher: effectiveFetcher,
    createContext: () => context,
    wait: abortableHold,
    onState: (snapshot) => states.push(snapshot),
    onError: (error) => errors.push(error),
    onUnauthorized: (error) => unauthorized.push(error),
    ...options,
  });
  return {
    context,
    errors,
    fetcher: effectiveFetcher,
    player,
    response,
    states,
    unauthorized,
  };
}

async function flushTasks() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function deferred() {
  let resolve;
  const promise = new Promise((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function timerHarness() {
  let nextIdentifier = 0;
  const active = new Map();
  const cleared = [];
  return {
    active,
    cleared,
    setTimeout(callback, milliseconds) {
      nextIdentifier += 1;
      active.set(nextIdentifier, { callback, milliseconds });
      return nextIdentifier;
    },
    clearTimeout(identifier) {
      cleared.push(identifier);
      active.delete(identifier);
    },
    fire(identifier = active.keys().next().value) {
      const timer = active.get(identifier);
      if (!timer) throw new Error(`Timer ${identifier} is not active.`);
      active.delete(identifier);
      timer.callback();
    },
  };
}

const originalAudioContext = globalThis.AudioContext;
const originalWebkitAudioContext = globalThis.webkitAudioContext;
const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.AudioContext = originalAudioContext;
  globalThis.webkitAudioContext = originalWebkitAudioContext;
  globalThis.fetch = originalFetch;
  vi.restoreAllMocks();
});

describe("streaming WAV decoding", () => {
  it("validates the exact browser playback format and accepts ArrayBuffer views", () => {
    const header = wavHeader();
    expect(parseStreamingWAVHeader(header.buffer)).toMatchObject({
      formatCode: 1,
      channelCount: 2,
      sampleRate: 48_000,
      blockAlign: 4,
      bitsPerSample: 16,
    });
    expect(parseStreamingWAVHeader(new DataView(header.buffer)).dataChunk).toBe("data");
    expect(() => parseStreamingWAVHeader(header.slice(0, 43))).toThrow(/incomplete/i);
    expect(() => parseStreamingWAVHeader("RIFF")).toThrow(TypeError);
  });

  it.each([
    ["RIFF", (_view, header) => header.set([...Buffer.from("NOPE")], 0)],
    ["WAVE", (_view, header) => header.set([...Buffer.from("NOPE")], 8)],
    ["fmt", (_view, header) => header.set([...Buffer.from("nope")], 12)],
    ["fmt size", (view) => view.setUint32(16, 18, true)],
    ["PCM", (view) => view.setUint16(20, 3, true)],
    ["stereo", (view) => view.setUint16(22, 1, true)],
    ["48 kHz", (view) => view.setUint32(24, 44_100, true)],
    ["byte rate", (view) => view.setUint32(28, 1, true)],
    ["block alignment", (view) => view.setUint16(32, 2, true)],
    ["PCM16", (view) => view.setUint16(34, 24, true)],
    ["data", (_view, header) => header.set([...Buffer.from("nope")], 36)],
  ])("rejects an invalid %s field", (_label, update) => {
    expect(() => parseStreamingWAVHeader(wavHeader(update)))
      .toThrow(/PCM16 stereo audio at 48 kHz/);
  });

  it("handles every header split and arbitrary stereo-frame boundaries", () => {
    const payload = pcm(5);
    for (let split = 0; split <= 44; split += 1) {
      const decoder = new StreamingWAVDecoder({ bufferFrames: 3 });
      expect([...decoder.push(wavHeader().slice(0, split))]).toEqual([]);
      const second = concatenate(wavHeader().slice(split), payload.slice(0, 5));
      const firstBlocks = [...decoder.push(second)];
      const secondBlocks = [...decoder.push(payload.slice(5))];
      const finalBlocks = decoder.finish();
      const blocks = [...firstBlocks, ...secondBlocks, ...finalBlocks];
      expect(blocks.map(({ frameCount }) => frameCount)).toEqual([3, 2]);
      expect(blocks[0].left[0]).toBe(-1);
      expect(blocks[0].left[1]).toBeCloseTo(32_767 / 32_768);
      expect(blocks[0].right[0]).toBe(0.5);
      expect(blocks[0].right[1]).toBe(-0.5);
    }
  });

  it("bounds pending data, flushes complete frames, and rejects truncated input", () => {
    const decoder = new StreamingWAVDecoder({ bufferFrames: 4 });
    expect([...decoder.push(new Uint8Array())]).toEqual([]);
    expect([
      ...decoder.push(concatenate(wavHeader(), pcm(2), new Uint8Array([1, 2]))),
    ]).toEqual([]);
    expect(decoder.pending.byteLength).toBe(10);
    expect(() => decoder.finish()).toThrow(/inside a stereo frame/i);

    const complete = new StreamingWAVDecoder({ bufferFrames: 4 });
    expect([...complete.push(concatenate(wavHeader(), pcm(2)))]).toEqual([]);
    expect(complete.finish()[0].frameCount).toBe(2);
    expect(complete.finish()).toEqual([]);

    expect(() => new StreamingWAVDecoder({ bufferFrames: 0 })).toThrow(RangeError);
    expect(() => [...new StreamingWAVDecoder().push({})]).toThrow(TypeError);
    expect(() => new StreamingWAVDecoder().finish()).toThrow(/before its WAV header/i);
  });

  it("caps individual decoder inputs while allowing the player to slice network chunks", async () => {
    const decoder = new StreamingWAVDecoder();
    expect(() => [
      ...decoder.push(new Uint8Array(decoder.maximumInputBytes + 1)),
    ]).toThrow(/exceeded the decoder limit/i);

    const context = new FakeContext();
    const wait = vi.fn(async () => {
      context.currentTime += 0.05;
    });
    const fixture = playerFixture({
      chunks: [concatenate(wavHeader(), pcm(18_000))],
      context,
      wait,
    });
    await fixture.player.start();
    await vi.waitFor(() => {
      expect(fixture.player.stats.receivedFrames).toBe(16_800);
    });
    expect(fixture.errors).toEqual([]);
    await fixture.player.stop();
  });
});

describe("live audio playback", () => {
  it("starts only on demand, fetches with safe options, schedules stereo, and cleans up", async () => {
    const fixture = playerFixture();
    expect(fixture.fetcher).not.toHaveBeenCalled();
    expect(fixture.context.resume).not.toHaveBeenCalled();

    const started = fixture.player.start();
    expect(fixture.context.resume).toHaveBeenCalledOnce();
    expect(fixture.player.state).toBe("starting");
    await started;

    expect(fixture.fetcher).toHaveBeenCalledWith("/audio/live.wav", expect.objectContaining({
      method: "GET",
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      headers: { Accept: "audio/wav" },
      signal: expect.any(AbortSignal),
    }));
    expect(fixture.context.buffers[0]).toMatchObject({
      channels: 2,
      frames: 2_400,
      sampleRate: 48_000,
    });
    expect(fixture.context.buffers[0].data[0][0]).toBe(-1);
    expect(fixture.context.sources[0].startedAt).toBeCloseTo(1.08);
    expect(fixture.player.snapshot()).toMatchObject({
      state: "playing",
      contextState: "running",
      receivedFrames: 2_400,
      scheduledFrames: 2_400,
      playedFrames: 0,
      activeSources: 1,
    });

    fixture.context.sources[0].finish();
    expect(fixture.player.snapshot()).toMatchObject({
      playedFrames: 2_400,
      activeSources: 0,
    });
    const stopped = await fixture.player.stop();
    expect(stopped.state).toBe("stopped");
    expect(fixture.response.reader.cancel).toHaveBeenCalledOnce();
    expect(fixture.context.close).toHaveBeenCalledOnce();
  });

  it("deduplicates concurrent starts and keeps scheduling lead bounded", async () => {
    const context = new FakeContext();
    const wait = vi.fn(async (_milliseconds, signal) => {
      if (signal.aborted) {
        const error = new Error("stopped");
        error.name = "AbortError";
        throw error;
      }
      context.currentTime += 0.05;
    });
    const chunks = [concatenate(wavHeader(), pcm(12_000))];
    const fixture = playerFixture({
      bufferFrames: 2_400,
      chunks,
      context,
      wait,
    });
    const first = fixture.player.start();
    const second = fixture.player.start();
    expect(second).toBe(first);
    await first;
    await vi.waitFor(() => {
      expect(fixture.player.stats.scheduledFrames).toBe(12_000);
    });
    expect(fixture.fetcher).toHaveBeenCalledOnce();
    expect(wait).toHaveBeenCalled();
    expect(fixture.player.snapshot().scheduledLeadSeconds).toBeLessThanOrEqual(0.25);
    await fixture.player.stop();
  });

  it("resumes a suspended context and publishes played-frame progress", async () => {
    const fixture = playerFixture();
    await fixture.player.start();
    fixture.context.state = "suspended";
    fixture.context.currentTime = 2;
    const block = {
      frameCount: 2_400,
      left: new Float32Array(2_400),
      right: new Float32Array(2_400),
    };
    await fixture.player.schedule(block, fixture.player.generation);
    expect(fixture.context.resume).toHaveBeenCalledTimes(2);
    fixture.context.sources[1].finish();
    expect(fixture.states.at(-1).playedFrames).toBe(2_400);
    await fixture.player.stop();
  });

  it("resumes an interrupted context before waiting on frozen scheduling lead", async () => {
    const context = new FakeContext();
    let resumeCount = 0;
    context.resume = vi.fn(async () => {
      resumeCount += 1;
      context.state = resumeCount === 2 ? "interrupted" : "running";
    });
    const wait = vi.fn(async () => {
      if (context.state === "interrupted") context.state = "running";
      else context.currentTime += 0.05;
    });
    const fixture = playerFixture({ context, wait });
    await fixture.player.start();
    const session = fixture.player.session;
    context.state = "interrupted";
    context.currentTime = 1;
    session.nextStartTime = 1.24;

    await fixture.player.schedule({
      frameCount: 2_400,
      left: new Float32Array(2_400),
      right: new Float32Array(2_400),
    }, fixture.player.generation);

    expect(context.resume).toHaveBeenCalledTimes(2);
    expect(wait).toHaveBeenCalled();
    expect(fixture.states.some(({ state }) => state === "reconnecting")).toBe(true);
    expect(fixture.player.state).toBe("playing");
    expect(fixture.player.snapshot().scheduledLeadSeconds).toBeLessThanOrEqual(0.25);
    await fixture.player.stop();
  });

  it("reconnects sequentially after a network failure", async () => {
    const response = responseWithChunks(
      [concatenate(wavHeader(), pcm(2_400))],
      { holdOpen: true },
    );
    const fetcher = vi.fn()
      .mockRejectedValueOnce(new TypeError("network reset"))
      .mockResolvedValueOnce(response);
    const context = new FakeContext();
    const wait = vi.fn(async (_milliseconds, signal) => {
      if (signal.aborted) throw Object.assign(new Error("stopped"), { name: "AbortError" });
    });
    const fixture = playerFixture({ context, fetcher, wait });
    await fixture.player.start();
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(fixture.states.some(({ state }) => state === "reconnecting")).toBe(true);
    expect(fixture.player.stats.reconnects).toBe(1);
    await fixture.player.stop();
  });

  it("reconnects after a retryable server response", async () => {
    const unavailable = responseWithChunks([], {
      ok: false,
      status: 503,
    });
    const available = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetcher = vi.fn()
      .mockResolvedValueOnce(unavailable)
      .mockResolvedValueOnce(available);
    const fixture = playerFixture({
      fetcher,
      wait: vi.fn(async () => {}),
    });
    await fixture.player.start();
    expect(fetcher).toHaveBeenCalledTimes(2);
    await fixture.player.stop();
  });

  it("resets reconnect backoff after each response schedules valid audio", async () => {
    const responses = [
      responseWithChunks([concatenate(wavHeader(), pcm(2_400))], { holdOpen: false }),
      responseWithChunks([concatenate(wavHeader(), pcm(2_400))], { holdOpen: false }),
      responseWithChunks([concatenate(wavHeader(), pcm(2_400))]),
    ];
    const fetcher = vi.fn()
      .mockResolvedValueOnce(responses[0])
      .mockResolvedValueOnce(responses[1])
      .mockResolvedValueOnce(responses[2]);
    const delays = [];
    const fixture = playerFixture({
      fetcher,
      wait: vi.fn(async (milliseconds) => {
        delays.push(milliseconds);
      }),
    });

    await fixture.player.start();
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3));
    expect(delays.slice(0, 2)).toEqual([500, 500]);
    expect(fixture.player.stats.reconnects).toBe(2);
    await fixture.player.stop();
  });

  it.each([
    ["HTTP errors", { ok: false, status: 422 }, "HTTP 422"],
    ["redirects", { redirected: true }, "must not redirect"],
    ["content types", { contentType: "text/html" }, "unexpected live audio format"],
  ])("fails terminally on unexpected %s", async (_label, responseOptions, message) => {
    const fixture = playerFixture({ responseOptions });
    await expect(fixture.player.start()).rejects.toThrow(message);
    await flushTasks();
    expect(fixture.player.state).toBe("failed");
    expect(fixture.errors).toHaveLength(1);
    expect(fixture.context.state).toBe("closed");
  });

  it("fails when the response body is unavailable", async () => {
    const fetcher = vi.fn(async () => ({
      ok: true,
      redirected: false,
      status: 200,
      headers: { get: () => "audio/wav" },
      body: null,
    }));
    const fixture = playerFixture({ fetcher });
    await expect(fixture.player.start()).rejects.toThrow(/no readable body/i);
    expect(fixture.errors[0].code).toBe("missing_audio_body");
  });

  it("cancels rejected and abnormally decoded response bodies", async () => {
    const rejectedResponse = responseWithChunks([], {
      contentType: "text/html",
    });
    const invalidResponse = responseWithChunks([
      concatenate(
        wavHeader((_view, header) => header.set([...Buffer.from("NOPE")], 0)),
        pcm(2_400),
      ),
    ]);
    const fetcher = vi.fn()
      .mockResolvedValueOnce(rejectedResponse)
      .mockResolvedValueOnce(invalidResponse);
    const contexts = [new FakeContext(), new FakeContext()];
    const player = new LiveAudioPlayer({
      fetcher,
      createContext: () => contexts.shift(),
      wait: abortableHold,
    });

    await expect(player.start()).rejects.toThrow(/unexpected live audio format/i);
    expect(rejectedResponse.body.cancel).toHaveBeenCalledOnce();
    await expect(player.start()).rejects.toThrow(/PCM16 stereo audio/i);
    expect(invalidResponse.reader.cancel).toHaveBeenCalledOnce();
  });

  it("cancels and reconnects when an open stream stops delivering samples", async () => {
    const timers = timerHarness();
    const neverCancels = new Promise(() => {});
    const stalled = responseWithChunks([], { cancelPromise: neverCancels });
    const recovered = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetcher = vi.fn()
      .mockResolvedValueOnce(stalled)
      .mockResolvedValueOnce(recovered);
    const fixture = playerFixture({
      fetcher,
      readTimeoutMilliseconds: 25,
      setTimeoutImpl: timers.setTimeout,
      clearTimeoutImpl: timers.clearTimeout,
      wait: vi.fn(async () => {}),
    });

    const started = fixture.player.start();
    await vi.waitFor(() => expect([...timers.active.values()]).toHaveLength(1));
    expect([...timers.active.values()][0].milliseconds).toBe(25);
    timers.fire();

    await started;
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(stalled.reader.cancel).toHaveBeenCalledOnce();
    expect(fixture.player.stats.reconnects).toBe(1);
    expect(fixture.player.state).toBe("playing");
    expect(timers.cleared.length).toBeGreaterThanOrEqual(3);
    await fixture.player.stop();
    await flushTasks();
    expect(timers.active.size).toBe(0);
  });

  it("times out response headers and retries with a request-local abort", async () => {
    const timers = timerHarness();
    const hangingFetch = new Promise(() => {});
    const recovered = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetchSignals = [];
    const fetcher = vi.fn((_url, options) => {
      fetchSignals.push(options.signal);
      return fetchSignals.length === 1 ? hangingFetch : Promise.resolve(recovered);
    });
    const fixture = playerFixture({
      fetcher,
      requestTimeoutMilliseconds: 40,
      setTimeoutImpl: timers.setTimeout,
      clearTimeoutImpl: timers.clearTimeout,
      wait: vi.fn(async () => {}),
    });

    const started = fixture.player.start();
    await vi.waitFor(() => expect([...timers.active.values()]).toHaveLength(1));
    expect([...timers.active.values()][0].milliseconds).toBe(40);
    timers.fire();

    await started;
    expect(fetchSignals[0].aborted).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(fixture.player.stats.reconnects).toBe(1);
    await fixture.player.stop();
  });

  it("retries an unsolicited AbortError without leaving a zombie session", async () => {
    const abort = Object.assign(new Error("transport aborted"), { name: "AbortError" });
    const recovered = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetcher = vi.fn()
      .mockRejectedValueOnce(abort)
      .mockResolvedValueOnce(recovered);
    const fixture = playerFixture({
      fetcher,
      wait: vi.fn(async () => {}),
    });

    await fixture.player.start();
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(fixture.player).toMatchObject({ state: "playing", active: true });
    expect(fixture.errors).toEqual([]);
    await fixture.player.stop();
  });

  it("returns to pairing on 401 without reporting a generic error", async () => {
    const fixture = playerFixture({
      responseOptions: { ok: false, status: 401 },
    });
    await expect(fixture.player.start()).rejects.toMatchObject({
      status: 401,
      code: "pairing_required",
    });
    await flushTasks();
    expect(fixture.unauthorized).toHaveLength(1);
    expect(fixture.errors).toEqual([]);
  });

  it("rejects startup without Web Audio and tolerates observer failures", async () => {
    globalThis.AudioContext = undefined;
    globalThis.webkitAudioContext = undefined;
    const observed = [];
    const player = new LiveAudioPlayer({
      onState: () => {
        throw new Error("render failed");
      },
      onError: (error) => {
        observed.push(error);
        throw new Error("observer failed");
      },
    });
    await expect(player.start()).rejects.toThrow(/does not support Web Audio/i);
    expect(player.state).toBe("failed");
    expect(observed).toHaveLength(1);
    await player.stop();
  });

  it("invalidates a pending start and permits a clean restart", async () => {
    let resolveFirstFetch;
    const firstFetch = new Promise((resolve) => {
      resolveFirstFetch = resolve;
    });
    const secondResponse = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetcher = vi.fn()
      .mockReturnValueOnce(firstFetch)
      .mockResolvedValueOnce(secondResponse);
    const contexts = [new FakeContext(), new FakeContext()];
    const player = new LiveAudioPlayer({
      fetcher,
      createContext: () => contexts.shift(),
      wait: abortableHold,
    });

    const pending = player.start();
    await flushTasks();
    const stopped = player.stop();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    await stopped;
    resolveFirstFetch(responseWithChunks([concatenate(wavHeader(), pcm(2_400))]));
    await flushTasks();

    await player.start();
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(player.state).toBe("playing");
    await player.stop();
  });

  it("keeps delayed teardown from stopping a restarted session", async () => {
    const delayedCancel = deferred();
    const firstResponse = responseWithChunks(
      [concatenate(wavHeader(), pcm(2_400))],
      { cancelPromise: delayedCancel.promise },
    );
    const secondResponse = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const fetcher = vi.fn()
      .mockResolvedValueOnce(firstResponse)
      .mockResolvedValueOnce(secondResponse);
    const contexts = [new FakeContext(), new FakeContext()];
    const firstContext = contexts[0];
    const secondContext = contexts[1];
    const player = new LiveAudioPlayer({
      fetcher,
      createContext: () => contexts.shift(),
      wait: abortableHold,
    });

    await player.start();
    const firstStop = player.stop();
    await expect(player.stop()).resolves.toMatchObject({ state: "stopped" });
    await player.start();
    expect(player.state).toBe("playing");
    expect(firstContext.sources[0].stop).toHaveBeenCalledOnce();
    expect(secondContext.sources[0].stop).not.toHaveBeenCalled();

    delayedCancel.resolve();
    await firstStop;
    expect(player.state).toBe("playing");
    expect(secondContext.close).not.toHaveBeenCalled();
    expect(secondContext.sources[0].stop).not.toHaveBeenCalled();
    await player.stop();
  });

  it("keeps failed-session cleanup from overwriting a stop and restart", async () => {
    const delayedClose = deferred();
    const firstContext = new FakeContext();
    firstContext.close = vi.fn(async () => {
      await delayedClose.promise;
      firstContext.state = "closed";
    });
    const secondContext = new FakeContext();
    const contexts = [firstContext, secondContext];
    const fetcher = vi.fn()
      .mockResolvedValueOnce(responseWithChunks([], { ok: false, status: 422 }))
      .mockResolvedValueOnce(responseWithChunks([concatenate(wavHeader(), pcm(2_400))]));
    const player = new LiveAudioPlayer({
      fetcher,
      createContext: () => contexts.shift(),
      wait: abortableHold,
    });

    await expect(player.start()).rejects.toThrow(/HTTP 422/);
    await player.stop();
    await player.start();
    expect(player.state).toBe("playing");

    delayedClose.resolve();
    await flushTasks();
    expect(player.state).toBe("playing");
    expect(secondContext.close).not.toHaveBeenCalled();
    await player.stop();
  });

  it("tolerates teardown races and release-lock errors", async () => {
    const context = new FakeContext({ cleanupErrors: true });
    const fixture = playerFixture({
      context,
      responseOptions: {
        releaseThrows: true,
        cancelThrows: true,
      },
    });
    await fixture.player.start();
    await expect(fixture.player.stop()).resolves.toMatchObject({ state: "stopped" });
    await expect(fixture.player.stop()).resolves.toMatchObject({ state: "stopped" });
  });

  it("rejects invalid scheduler configuration and a closed context", async () => {
    expect(() => new LiveAudioPlayer({
      targetLeadSeconds: 0.25,
      maxLeadSeconds: 0.25,
    })).toThrow(RangeError);
    expect(() => new LiveAudioPlayer({
      bufferFrames: 10_000,
    })).toThrow(/exceed the maximum scheduling lead/i);
    expect(() => new LiveAudioPlayer({
      maxLeadSeconds: Number.POSITIVE_INFINITY,
    })).toThrow(/maximum audio lead/i);
    expect(() => new LiveAudioPlayer({
      reconnectDelayMilliseconds: Number.NaN,
    })).toThrow(/reconnectDelayMilliseconds/i);
    expect(() => new LiveAudioPlayer({
      reconnectDelayMilliseconds: -1,
    })).toThrow(/reconnectDelayMilliseconds/i);
    expect(() => new LiveAudioPlayer({
      readTimeoutMilliseconds: 0,
    })).toThrow(/readTimeoutMilliseconds/i);
    expect(() => new LiveAudioPlayer({
      requestTimeoutMilliseconds: Number.POSITIVE_INFINITY,
    })).toThrow(/requestTimeoutMilliseconds/i);

    const context = new FakeContext();
    const fixture = playerFixture({ context });
    const starting = fixture.player.start();
    context.state = "closed";
    await expect(starting).rejects.toThrow(/closed its audio output/i);
  });

  it("uses the global fetch and AudioContext defaults", async () => {
    const context = new FakeContext();
    const response = responseWithChunks([concatenate(wavHeader(), pcm(2_400))]);
    const Context = vi.fn(function Context() {
      return context;
    });
    globalThis.AudioContext = Context;
    globalThis.fetch = vi.fn(async () => response);
    const player = new LiveAudioPlayer({ wait: abortableHold });
    await player.start();
    expect(Context).toHaveBeenCalledWith({ latencyHint: "interactive" });
    expect(globalThis.fetch).toHaveBeenCalledOnce();
    await player.stop();
  });

  it("identifies LiveAudioError metadata", () => {
    const error = new LiveAudioError("failure", {
      code: "test",
      status: 500,
      retryable: true,
    });
    expect(error).toMatchObject({
      name: "LiveAudioError",
      message: "failure",
      code: "test",
      status: 500,
      retryable: true,
    });
  });
});

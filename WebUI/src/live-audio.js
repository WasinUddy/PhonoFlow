const WAV_HEADER_BYTES = 44;
const PCM_FRAME_BYTES = 4;
const DEFAULT_BUFFER_FRAMES = 2_400;
const DEFAULT_TARGET_LEAD_SECONDS = 0.08;
const DEFAULT_MAX_LEAD_SECONDS = 0.25;
const DEFAULT_RECONNECT_DELAY_MS = 500;
const DEFAULT_MAXIMUM_INPUT_BYTES = 64 * 1_024;
const DEFAULT_REQUEST_TIMEOUT_MS = 5_000;
const DEFAULT_READ_TIMEOUT_MS = 5_000;

function abortError() {
  if (typeof DOMException === "function") {
    return new DOMException("Live audio playback stopped.", "AbortError");
  }
  const error = new Error("Live audio playback stopped.");
  error.name = "AbortError";
  return error;
}

function isAbortError(error) {
  return error?.name === "AbortError";
}

function bytes(value) {
  if (value instanceof Uint8Array) return value;
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw new TypeError("Live WAV chunks must be byte arrays.");
}

function text(value, start, end) {
  return String.fromCharCode(...value.subarray(start, end));
}

function defaultWait(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(abortError());
      return;
    }
    const complete = () => {
      signal.removeEventListener("abort", cancel);
      resolve();
    };
    const cancel = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    const timer = setTimeout(complete, milliseconds);
    signal.addEventListener("abort", cancel, { once: true });
  });
}

export class LiveAudioError extends Error {
  constructor(message, { code = "playback_failed", status = 0, retryable = false } = {}) {
    super(message);
    this.name = "LiveAudioError";
    this.code = code;
    this.status = status;
    this.retryable = retryable;
  }
}

export function parseStreamingWAVHeader(value) {
  const header = bytes(value);
  if (header.byteLength < WAV_HEADER_BYTES) {
    throw new LiveAudioError("The live WAV header is incomplete.", {
      code: "invalid_wav_header",
    });
  }

  const view = new DataView(header.buffer, header.byteOffset, WAV_HEADER_BYTES);
  const format = {
    riff: text(header, 0, 4),
    wave: text(header, 8, 12),
    formatChunk: text(header, 12, 16),
    formatChunkBytes: view.getUint32(16, true),
    formatCode: view.getUint16(20, true),
    channelCount: view.getUint16(22, true),
    sampleRate: view.getUint32(24, true),
    byteRate: view.getUint32(28, true),
    blockAlign: view.getUint16(32, true),
    bitsPerSample: view.getUint16(34, true),
    dataChunk: text(header, 36, 40),
  };
  const valid = format.riff === "RIFF"
    && format.wave === "WAVE"
    && format.formatChunk === "fmt "
    && format.formatChunkBytes === 16
    && format.formatCode === 1
    && format.channelCount === 2
    && format.sampleRate === 48_000
    && format.byteRate === 192_000
    && format.blockAlign === PCM_FRAME_BYTES
    && format.bitsPerSample === 16
    && format.dataChunk === "data";
  if (!valid) {
    throw new LiveAudioError(
      "Browser listening requires PCM16 stereo audio at 48 kHz.",
      { code: "unsupported_wav_format" },
    );
  }
  return Object.freeze(format);
}

function decodePCM16Stereo(value, offset, byteLength) {
  const frameCount = byteLength / PCM_FRAME_BYTES;
  const left = new Float32Array(frameCount);
  const right = new Float32Array(frameCount);
  const view = new DataView(value.buffer, value.byteOffset + offset, byteLength);
  for (let frame = 0; frame < frameCount; frame += 1) {
    const byteOffset = frame * PCM_FRAME_BYTES;
    left[frame] = view.getInt16(byteOffset, true) / 32_768;
    right[frame] = view.getInt16(byteOffset + 2, true) / 32_768;
  }
  return { left, right, frameCount };
}

/**
 * Incrementally validates the fixed streaming WAV header and emits bounded
 * planar Float32 blocks. Fewer than one scheduling block is retained between
 * network reads, including at most three partial frame bytes.
 */
export class StreamingWAVDecoder {
  constructor({ bufferFrames = DEFAULT_BUFFER_FRAMES } = {}) {
    if (!Number.isInteger(bufferFrames) || bufferFrames <= 0) {
      throw new RangeError("bufferFrames must be a positive integer.");
    }
    this.bufferFrames = bufferFrames;
    this.blockBytes = bufferFrames * PCM_FRAME_BYTES;
    this.maximumInputBytes = Math.max(DEFAULT_MAXIMUM_INPUT_BYTES, this.blockBytes);
    this.header = new Uint8Array(WAV_HEADER_BYTES);
    this.headerLength = 0;
    this.format = null;
    this.pending = new Uint8Array();
  }

  *push(value) {
    let chunk = bytes(value);
    if (chunk.byteLength === 0) return;
    if (chunk.byteLength > this.maximumInputBytes) {
      throw new LiveAudioError("A live audio network chunk exceeded the decoder limit.", {
        code: "audio_chunk_too_large",
      });
    }

    if (!this.format) {
      const required = WAV_HEADER_BYTES - this.headerLength;
      const copied = Math.min(required, chunk.byteLength);
      this.header.set(chunk.subarray(0, copied), this.headerLength);
      this.headerLength += copied;
      chunk = chunk.subarray(copied);
      if (this.headerLength < WAV_HEADER_BYTES) return;
      this.format = parseStreamingWAVHeader(this.header);
    }

    if (chunk.byteLength === 0) return;
    const combined = new Uint8Array(this.pending.byteLength + chunk.byteLength);
    combined.set(this.pending);
    combined.set(chunk, this.pending.byteLength);

    let offset = 0;
    while (combined.byteLength - offset >= this.blockBytes) {
      yield decodePCM16Stereo(combined, offset, this.blockBytes);
      offset += this.blockBytes;
    }
    this.pending = combined.slice(offset);
  }

  finish() {
    if (!this.format) {
      throw new LiveAudioError("The live audio stream ended before its WAV header.", {
        code: "truncated_wav_stream",
        retryable: true,
      });
    }
    if (this.pending.byteLength % PCM_FRAME_BYTES !== 0) {
      throw new LiveAudioError("The live audio stream ended inside a stereo frame.", {
        code: "truncated_pcm_frame",
        retryable: true,
      });
    }
    if (this.pending.byteLength === 0) return [];
    const block = decodePCM16Stereo(this.pending, 0, this.pending.byteLength);
    this.pending = new Uint8Array();
    return [block];
  }
}

function createDefaultContext() {
  const Context = globalThis.AudioContext ?? globalThis.webkitAudioContext;
  if (typeof Context !== "function") {
    throw new LiveAudioError("This browser does not support Web Audio playback.", {
      code: "web_audio_unavailable",
    });
  }
  return new Context({ latencyHint: "interactive" });
}

function defaultFetch(...arguments_) {
  return globalThis.fetch(...arguments_);
}

function cancelResponseBody(response) {
  try {
    const cancellation = response.body?.cancel?.();
    void Promise.resolve(cancellation).catch(() => {});
  } catch {
    // Invalid or rejected responses may close while cancellation is requested.
  }
}

function cancelAndReleaseReader(reader) {
  if (!reader) return;
  let cancellation;
  try {
    cancellation = reader.cancel();
  } catch {
    // A request abort can close or unlock a reader before cancellation runs.
  }
  void Promise.resolve(cancellation).catch(() => {}).finally(() => {
    try {
      reader.releaseLock();
    } catch {
      // A permanently pending browser read remains owned by the aborted request.
    }
  });
}

function closeContext(context) {
  if (!context || context.state === "closed") return;
  try {
    const closing = context.close();
    void Promise.resolve(closing).catch(() => {});
  } catch {
    // Page teardown can close the context before cleanup reaches it.
  }
}

export class LiveAudioPlayer {
  constructor({
    url = "/audio/live.wav",
    fetcher = defaultFetch,
    createContext = createDefaultContext,
    wait = defaultWait,
    onState = () => {},
    onError = () => {},
    onUnauthorized = () => {},
    bufferFrames = DEFAULT_BUFFER_FRAMES,
    targetLeadSeconds = DEFAULT_TARGET_LEAD_SECONDS,
    maxLeadSeconds = DEFAULT_MAX_LEAD_SECONDS,
    reconnectDelayMilliseconds = DEFAULT_RECONNECT_DELAY_MS,
    requestTimeoutMilliseconds = DEFAULT_REQUEST_TIMEOUT_MS,
    readTimeoutMilliseconds = DEFAULT_READ_TIMEOUT_MS,
    setTimeoutImpl = globalThis.setTimeout?.bind(globalThis),
    clearTimeoutImpl = globalThis.clearTimeout?.bind(globalThis),
  } = {}) {
    if (
      !Number.isFinite(targetLeadSeconds)
      || !Number.isFinite(maxLeadSeconds)
      || !(targetLeadSeconds >= 0 && maxLeadSeconds > targetLeadSeconds)
    ) {
      throw new RangeError("The maximum audio lead must exceed the target lead.");
    }
    if (!Number.isSafeInteger(bufferFrames) || bufferFrames <= 0) {
      throw new RangeError("bufferFrames must be a positive integer.");
    }
    if (targetLeadSeconds + (bufferFrames / 48_000) > maxLeadSeconds) {
      throw new RangeError("One audio buffer would exceed the maximum scheduling lead.");
    }
    if (!Number.isFinite(readTimeoutMilliseconds) || readTimeoutMilliseconds <= 0) {
      throw new RangeError("readTimeoutMilliseconds must be positive and finite.");
    }
    if (!Number.isFinite(requestTimeoutMilliseconds) || requestTimeoutMilliseconds <= 0) {
      throw new RangeError("requestTimeoutMilliseconds must be positive and finite.");
    }
    if (
      !Number.isFinite(reconnectDelayMilliseconds)
      || reconnectDelayMilliseconds < 0
    ) {
      throw new RangeError("reconnectDelayMilliseconds must be finite and nonnegative.");
    }
    if (typeof setTimeoutImpl !== "function" || typeof clearTimeoutImpl !== "function") {
      throw new TypeError("Live audio playback requires timer functions.");
    }
    this.url = url;
    this.fetcher = fetcher;
    this.createContext = createContext;
    this.wait = wait;
    this.onState = onState;
    this.onError = onError;
    this.onUnauthorized = onUnauthorized;
    this.bufferFrames = bufferFrames;
    this.targetLeadSeconds = targetLeadSeconds;
    this.maxLeadSeconds = maxLeadSeconds;
    this.reconnectDelayMilliseconds = reconnectDelayMilliseconds;
    this.requestTimeoutMilliseconds = requestTimeoutMilliseconds;
    this.readTimeoutMilliseconds = readTimeoutMilliseconds;
    this.setTimeout = setTimeoutImpl;
    this.clearTimeout = clearTimeoutImpl;
    this.generation = 0;
    this.state = "stopped";
    this.session = null;
    this.lastPublishedPlayedFrames = 0;
    this.stats = this.emptyStats();
  }

  get active() {
    return this.session !== null
      && ["starting", "playing", "reconnecting"].includes(this.state);
  }

  emptyStats() {
    return {
      receivedBytes: 0,
      receivedFrames: 0,
      scheduledFrames: 0,
      playedFrames: 0,
      reconnects: 0,
    };
  }

  snapshot() {
    const session = this.session;
    return Object.freeze({
      state: this.state,
      contextState: session?.context.state ?? "closed",
      ...this.stats,
      activeSources: session?.sources.size ?? 0,
      scheduledLeadSeconds: Math.max(
        0,
        (session?.nextStartTime ?? 0) - (session?.context.currentTime ?? 0),
      ),
    });
  }

  start() {
    if (this.active) {
      return this.session.startPromise ?? Promise.resolve(this.snapshot());
    }

    const generation = this.generation + 1;
    this.generation = generation;
    this.lastPublishedPlayedFrames = 0;
    const controller = new AbortController();
    const stats = this.emptyStats();
    this.stats = stats;

    let context;
    try {
      context = this.createContext();
    } catch (error) {
      this.failSynchronously(error);
      return Promise.reject(error);
    }

    let resumePromise;
    try {
      // This invocation must remain synchronous with the trusted click so
      // WebKit does not consume the transient user activation first.
      resumePromise = Promise.resolve(context.resume());
    } catch (error) {
      resumePromise = Promise.reject(error);
    }

    const session = {
      context,
      controller,
      generation,
      nextStartTime: 0,
      request: null,
      reconnectAttempt: 0,
      rejectStart: null,
      resolveStart: null,
      sources: new Set(),
      startPromise: null,
      stats,
    };
    session.startPromise = new Promise((resolve, reject) => {
      session.resolveStart = resolve;
      session.rejectStart = reject;
    });
    this.session = session;
    this.emitFor(session, "starting");
    void this.run(session, resumePromise);
    return session.startPromise;
  }

  async stop() {
    const session = this.session;
    if (session === null) {
      if (this.state !== "stopped") this.emit("stopped");
      return this.snapshot();
    }

    this.session = null;
    this.generation += 1;
    const rejection = session.rejectStart;
    this.clearStartPromise(session);
    rejection?.(abortError());
    this.emit("stopped");
    const stoppedSnapshot = this.snapshot();
    await this.releaseResources(session);
    return stoppedSnapshot;
  }

  async run(session, resumePromise) {
    try {
      await resumePromise;
      this.requireCurrent(session);
      while (this.session === session && !session.controller.signal.aborted) {
        try {
          await this.consumeResponse(session);
          throw new LiveAudioError("The live audio stream ended; reconnecting.", {
            code: "live_stream_ended",
            retryable: true,
          });
        } catch (error) {
          if (this.session !== session || session.controller.signal.aborted) return;
          if (!this.retryable(error)) throw error;
          session.reconnectAttempt += 1;
          session.stats.reconnects += 1;
          this.emitFor(session, "reconnecting");
          const delay = Math.min(
            this.reconnectDelayMilliseconds * (2 ** (session.reconnectAttempt - 1)),
            4_000,
          );
          await this.wait(delay, session.controller.signal);
        }
      }
    } catch (error) {
      if (this.session !== session || session.controller.signal.aborted) return;
      await this.fail(error, session);
    }
  }

  async consumeResponse(session) {
    const request = {
      cancellationRequested: false,
      controller: new AbortController(),
      reader: null,
    };
    session.request = request;
    const stopRequest = () => request.controller.abort();
    session.controller.signal.addEventListener("abort", stopRequest, { once: true });
    try {
      const fetchPromise = Promise.resolve(this.fetcher(this.url, {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "audio/wav" },
        signal: request.controller.signal,
      }));
      void fetchPromise.then((lateResponse) => {
        if (request.controller.signal.aborted) cancelResponseBody(lateResponse);
      }, () => {});
      const response = await this.withTimeout(
        fetchPromise,
        this.requestTimeoutMilliseconds,
        () => new LiveAudioError(
          "The Mac did not respond to the live audio request; reconnecting.",
          { code: "live_request_timeout", retryable: true },
        ),
        () => request.controller.abort(),
      );
      this.requireCurrent(session);

      if (response.status === 401) {
        cancelResponseBody(response);
        throw new LiveAudioError("Pair this browser again to resume listening.", {
          code: "pairing_required",
          status: 401,
        });
      }
      if (!response.ok) {
        cancelResponseBody(response);
        throw new LiveAudioError(`The Mac returned HTTP ${response.status} for live audio.`, {
          code: "audio_http_error",
          status: response.status,
          retryable: response.status >= 500,
        });
      }
      if (response.redirected) {
        cancelResponseBody(response);
        throw new LiveAudioError("The live audio endpoint must not redirect.", {
          code: "unexpected_audio_redirect",
        });
      }
      const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
      if (!contentType.startsWith("audio/wav")) {
        cancelResponseBody(response);
        throw new LiveAudioError("The Mac returned an unexpected live audio format.", {
          code: "unexpected_audio_content_type",
        });
      }
      const reader = response.body?.getReader();
      if (!reader) {
        throw new LiveAudioError("The live audio response has no readable body.", {
          code: "missing_audio_body",
        });
      }

      const decoder = new StreamingWAVDecoder({ bufferFrames: this.bufferFrames });
      request.reader = reader;
      while (this.session === session && !session.controller.signal.aborted) {
        const result = await this.withTimeout(
          reader.read(),
          this.readTimeoutMilliseconds,
          () => new LiveAudioError(
            "The live audio stream stopped delivering samples; reconnecting.",
            { code: "live_stream_timeout", retryable: true },
          ),
          () => request.controller.abort(),
        );
        this.requireCurrent(session);
        if (result.done) {
          for (const block of decoder.finish()) {
            session.stats.receivedFrames += block.frameCount;
            await this.schedule(block, session);
          }
          return;
        }
        const chunk = bytes(result.value);
        session.stats.receivedBytes += chunk.byteLength;
        for (let offset = 0; offset < chunk.byteLength; offset += decoder.maximumInputBytes) {
          const end = Math.min(offset + decoder.maximumInputBytes, chunk.byteLength);
          for (const block of decoder.push(chunk.subarray(offset, end))) {
            session.stats.receivedFrames += block.frameCount;
            await this.schedule(block, session);
          }
        }
      }
    } finally {
      session.controller.signal.removeEventListener("abort", stopRequest);
      if (session.request === request) session.request = null;
      request.controller.abort();
      const reader = request.reader;
      request.reader = null;
      if (!request.cancellationRequested) cancelAndReleaseReader(reader);
    }
  }

  async withTimeout(operation, milliseconds, error, onTimeout = () => {}) {
    let timer = null;
    const timeout = new Promise((_, reject) => {
      timer = this.setTimeout(() => {
        reject(error());
        try {
          onTimeout();
        } catch {
          // The timeout error remains authoritative if abort cleanup races.
        }
      }, milliseconds);
    });
    try {
      return await Promise.race([operation, timeout]);
    } finally {
      if (timer !== null) this.clearTimeout(timer);
    }
  }

  async schedule(block, sessionOrGeneration) {
    const session = this.currentSession(sessionOrGeneration);
    this.requireCurrent(session);
    const duration = block.frameCount / 48_000;
    await this.ensureContextRunning(session);
    await this.waitForCapacity(duration, session);
    await this.ensureContextRunning(session);
    this.requireCurrent(session);

    const buffer = session.context.createBuffer(2, block.frameCount, 48_000);
    buffer.copyToChannel(block.left, 0);
    buffer.copyToChannel(block.right, 1);
    const source = session.context.createBufferSource();
    source.buffer = buffer;
    source.connect(session.context.destination);

    const startTime = Math.max(
      session.nextStartTime,
      session.context.currentTime + this.targetLeadSeconds,
    );
    session.nextStartTime = startTime + duration;
    session.sources.add(source);
    session.stats.scheduledFrames += block.frameCount;
    session.reconnectAttempt = 0;
    source.onended = () => {
      session.sources.delete(source);
      try {
        source.disconnect();
      } catch {
        // A stopped source may already be disconnected.
      }
      if (this.session !== session) return;
      session.stats.playedFrames += block.frameCount;
      if (
        this.lastPublishedPlayedFrames === 0
        || session.stats.playedFrames - this.lastPublishedPlayedFrames >= 12_000
      ) {
        this.lastPublishedPlayedFrames = session.stats.playedFrames;
        this.emitFor(session);
      }
    };
    source.start(startTime);

    if (this.state !== "playing") {
      this.emitFor(session, "playing");
      const resolve = session.resolveStart;
      this.clearStartPromise(session);
      resolve?.(this.snapshot());
    }
  }

  async ensureContextRunning(session) {
    while (this.session === session) {
      const { context } = session;
      if (context.state === "running") {
        if (session.sources.size === 0) session.nextStartTime = 0;
        return;
      }
      if (context.state === "closed") {
        throw new LiveAudioError("The browser closed its audio output.", {
          code: "audio_context_closed",
        });
      }
      if (context.state !== "suspended" && context.state !== "interrupted") {
        throw new LiveAudioError(`The browser audio output entered ${context.state}.`, {
          code: "audio_context_unavailable",
        });
      }

      await context.resume();
      this.requireCurrent(session);
      if (context.state === "running") {
        if (session.sources.size === 0) session.nextStartTime = 0;
        return;
      }
      this.emitFor(session, "reconnecting");
      await this.wait(50, session.controller.signal);
      this.requireCurrent(session);
    }
    throw abortError();
  }

  async waitForCapacity(duration, session) {
    while (this.session === session) {
      await this.ensureContextRunning(session);
      if (session.sources.size === 0) {
        session.nextStartTime = 0;
        return;
      }
      const lead = Math.max(0, session.nextStartTime - session.context.currentTime);
      if (lead + duration <= this.maxLeadSeconds) return;
      const milliseconds = Math.max(
        5,
        Math.min(50, (lead + duration - this.maxLeadSeconds) * 1_000),
      );
      await this.wait(milliseconds, session.controller.signal);
      this.requireCurrent(session);
    }
    throw abortError();
  }

  retryable(error) {
    return error?.retryable === true
      || isAbortError(error)
      || error instanceof TypeError;
  }

  currentSession(sessionOrGeneration) {
    const session = typeof sessionOrGeneration === "number"
      ? this.session
      : sessionOrGeneration;
    if (
      session === null
      || session === undefined
      || (
        typeof sessionOrGeneration === "number"
        && session.generation !== sessionOrGeneration
      )
    ) {
      throw abortError();
    }
    return session;
  }

  requireCurrent(session) {
    if (
      this.session !== session
      || session.generation !== this.generation
      || session.controller.signal.aborted
    ) {
      throw abortError();
    }
  }

  async fail(error, session) {
    if (this.session !== session) return;
    this.session = null;
    const rejection = session.rejectStart;
    this.clearStartPromise(session);
    rejection?.(error);
    this.emit("failed");
    try {
      if (error?.status === 401) this.onUnauthorized(error);
      else this.onError(error);
    } catch {
      // UI callbacks must not destabilize audio cleanup.
    }
    await this.releaseResources(session);
  }

  failSynchronously(error) {
    this.emit("failed");
    try {
      this.onError(error);
    } catch {
      // UI callbacks must not replace the original startup error.
    }
  }

  clearStartPromise(session) {
    session.startPromise = null;
    session.resolveStart = null;
    session.rejectStart = null;
  }

  releaseResources(session) {
    const { context, controller, request } = session;
    const sources = [...session.sources];
    session.request = null;
    session.nextStartTime = 0;
    session.sources.clear();
    controller.abort();
    request?.controller.abort();
    const reader = request?.reader;
    if (request) {
      request.cancellationRequested = true;
      request.reader = null;
    }
    cancelAndReleaseReader(reader);
    for (const source of sources) {
      source.onended = null;
      try {
        source.stop();
      } catch {
        // A source that already ended cannot be stopped again.
      }
      try {
        source.disconnect();
      } catch {
        // A source may already have been disconnected by its ended callback.
      }
    }

    closeContext(context);
  }

  emitFor(session, state = this.state) {
    if (this.session !== session) return;
    this.emit(state);
  }

  emit(state = this.state) {
    this.state = state;
    try {
      this.onState(this.snapshot());
    } catch {
      // Rendering callbacks are observers, not part of the audio pipeline.
    }
  }
}

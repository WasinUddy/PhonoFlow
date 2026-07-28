export const EQ_FREQUENCIES = Object.freeze([
  31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
]);

const ENGINE_STATES = new Set(["idle", "starting", "running", "disconnected", "failed"]);
const CONNECTION_STATES = new Set(["connecting", "connected", "reconnecting", "disconnected"]);

const finite = (value, fallback = 0) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
};

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

export function linearGainToDB(gain) {
  const normalized = finite(gain, 1);
  if (normalized <= 0) return -60;
  return 20 * Math.log10(clamp(normalized, 0.001, 100));
}

export function decibelsToLinearGain(decibels) {
  const normalized = finite(decibels);
  if (normalized <= -60) return 0;
  return clamp(10 ** (normalized / 20), 0, 4);
}

export function defaultEqualizerBands() {
  return EQ_FREQUENCIES.map((frequencyHz) => ({ frequencyHz, gainDB: 0 }));
}

export function createInitialState() {
  return {
    authenticated: false,
    hasSnapshot: false,
    connection: "connecting",
    revision: 0,
    engine: {
      state: "idle",
      format: null,
      error: null,
    },
    devices: {
      inputs: [],
      outputs: [],
    },
    selection: {
      inputUID: null,
      inputRouteID: null,
      outputUID: null,
    },
    monitor: { enabled: false },
    processing: {
      gainDB: 0,
      autoGainEnabled: false,
    },
    equalizer: {
      bands: defaultEqualizerBands(),
    },
    radio: {
      enabled: false,
      listenerCount: 0,
      url: "/stream",
    },
    recording: {
      enabled: false,
      durationSeconds: 0,
      fileName: null,
    },
    telemetry: {
      droppedFrames: 0,
      xruns: 0,
    },
    meters: {
      sequence: -1,
      left: 0,
      right: 0,
      leftDB: -60,
      rightDB: -60,
      peak: 0,
      timestamp: null,
    },
    spectrogram: {
      sequence: -1,
      timestamp: null,
      intensities: null,
      paused: false,
    },
    pairing: {
      busy: false,
      error: "",
    },
    pending: {},
    error: null,
  };
}

function routeLabel(route, index) {
  const sourceChannels = route?.channelIndices ?? route?.channels;
  const indices = Array.isArray(sourceChannels)
    ? sourceChannels.map((value) => finite(value, 0))
    : [];
  const providedLabel = route?.name ?? route?.label;
  if (typeof providedLabel === "string" && providedLabel.trim()) return providedLabel.trim();
  if (indices.length >= 2) return `Inputs ${indices[0] + 1}–${indices[1] + 1}`;
  return `Input pair ${index + 1}`;
}

function normalizeRoute(route, index) {
  const sourceChannels = route?.channelIndices ?? route?.channels;
  const channelIndices = Array.isArray(sourceChannels)
    ? sourceChannels.slice(0, 2).map((value) => Math.max(0, Math.trunc(finite(value, 0))))
    : [index * 2, index * 2 + 1];
  return {
    id: String(route?.id ?? `pair-${index + 1}`),
    name: routeLabel(route, index),
    channelIndices,
  };
}

function normalizeDevice(device, index, kind) {
  const uid = String(device?.uid ?? device?.id ?? `${kind}-${index + 1}`);
  const roleChannelCount = kind === "input"
    ? device?.inputChannelCount
    : device?.outputChannelCount;
  const channelCount = Math.max(0, Math.trunc(finite(
    roleChannelCount ?? device?.channelCount ?? device?.channels,
    0,
  )));
  const rawRoutes = device?.inputRoutes ?? device?.routes;
  let inputRoutes = [];

  if (kind === "input") {
    if (Array.isArray(rawRoutes) && rawRoutes.length) {
      inputRoutes = rawRoutes.map(normalizeRoute);
    } else if (channelCount === 1) {
      inputRoutes = [{ id: "mono", name: "Input 1 (dual mono)", channelIndices: [0, 0] }];
    } else {
      for (let channel = 0; channel < channelCount; channel += 2) {
        const right = Math.min(channel + 1, channelCount - 1);
        inputRoutes.push({
          id: `pair-${channel + 1}-${right + 1}`,
          name: `Inputs ${channel + 1}–${right + 1}`,
          channelIndices: [channel, right],
        });
      }
    }
  }

  return {
    uid,
    name: String(device?.name ?? `${kind === "input" ? "Input" : "Output"} ${index + 1}`),
    connected: device?.connected !== false && device?.connectionState !== "disconnected",
    channelCount,
    inputRoutes,
    sampleRates: Array.isArray(device?.sampleRates ?? device?.supportedSampleRates)
      ? (device.sampleRates ?? device.supportedSampleRates)
        .map((rate) => finite(rate))
        .filter((rate) => rate > 0)
      : [],
    transport: device?.transport ? String(device.transport) : null,
  };
}

function normalizeDevices(raw, previous) {
  if (Array.isArray(raw)) {
    return {
      inputs: raw
        .filter((device) => finite(device?.inputChannelCount, 0) > 0)
        .map((device, index) => normalizeDevice(device, index, "input")),
      outputs: raw
        .filter((device) => finite(device?.outputChannelCount, 0) > 0)
        .map((device, index) => normalizeDevice(device, index, "output")),
    };
  }
  const source = raw ?? {};
  const inputSource = source.inputs ?? source.inputDevices;
  const outputSource = source.outputs ?? source.outputDevices;
  return {
    inputs: Array.isArray(inputSource)
      ? inputSource.map((device, index) => normalizeDevice(device, index, "input"))
      : previous.inputs,
    outputs: Array.isArray(outputSource)
      ? outputSource.map((device, index) => normalizeDevice(device, index, "output"))
      : previous.outputs,
  };
}

function normalizeSelection(raw, previous) {
  if (raw === null) {
    return { inputUID: null, inputRouteID: null, outputUID: null };
  }
  const source = raw ?? {};
  return {
    inputUID: source.inputUID === null
      ? null
      : String(source.inputUID ?? previous.inputUID ?? "") || null,
    inputRouteID: source.inputRouteID === null
      ? null
      : String(source.inputRouteID ?? previous.inputRouteID ?? "") || null,
    outputUID: source.outputUID === null
      ? null
      : String(source.outputUID ?? previous.outputUID ?? "") || null,
  };
}

function normalizeFormat(raw, previous) {
  if (raw === null) return null;
  if (!raw || typeof raw !== "object") return previous;
  return {
    sampleRate: finite(raw.sampleRate ?? raw.rate, previous?.sampleRate ?? 0),
    channelCount: Math.max(0, Math.trunc(finite(raw.channelCount ?? raw.channels, previous?.channelCount ?? 0))),
    bufferFrames: Math.max(0, Math.trunc(finite(
      raw.bufferFrames ?? raw.bufferFrameCount ?? raw.bufferSize,
      previous?.bufferFrames ?? 0,
    ))),
    sampleFormat: String(raw.sampleFormat ?? raw.format ?? previous?.sampleFormat ?? "Float32"),
  };
}

function normalizeEngine(raw, previous) {
  const source = raw ?? {};
  const state = String(source.state ?? source.phase ?? previous.state).toLowerCase();
  const serverError = source.error ?? source.problem;
  return {
    state: ENGINE_STATES.has(state) ? state : previous.state,
    format: normalizeFormat(source.format, previous.format),
    error: serverError === null
      ? null
      : serverError
        ? {
            title: String(serverError.title ?? "Audio engine error"),
            detail: String(serverError.detail ?? serverError.message ?? serverError),
          }
        : previous.error,
  };
}

function normalizeEqualizer(raw, previous) {
  const source = raw?.bands ?? raw;
  if (!Array.isArray(source) || source.length === 0) return previous;

  const byFrequency = new Map(previous.bands.map((band) => [band.frequencyHz, band.gainDB]));
  const bands = EQ_FREQUENCIES.map((frequencyHz, index) => {
    const item = source[index];
    if (typeof item === "number") {
      return { frequencyHz, gainDB: clamp(finite(item), -12, 12) };
    }
    if (item && typeof item === "object") {
      const itemFrequency = Math.trunc(finite(item.frequencyHz ?? item.frequency, frequencyHz));
      return {
        frequencyHz: itemFrequency,
        gainDB: clamp(finite(item.gainDB ?? item.gain, byFrequency.get(frequencyHz) ?? 0), -12, 12),
      };
    }
    return { frequencyHz, gainDB: byFrequency.get(frequencyHz) ?? 0 };
  });
  return { bands };
}

function normalizeProcessing(raw, previous) {
  const source = raw ?? {};
  const gainDB = source.gainDB !== undefined
    ? finite(source.gainDB, previous.gainDB)
    : source.gain !== undefined
      ? linearGainToDB(source.gain)
      : previous.gainDB;
  return {
    gainDB: clamp(gainDB, -60, 12),
    autoGainEnabled: Boolean(source.autoGainEnabled ?? source.autoGain ?? previous.autoGainEnabled),
  };
}

function normalizeSimpleEnabled(raw, previous) {
  if (typeof raw === "boolean") return { ...previous, enabled: raw };
  return {
    ...previous,
    ...(raw && typeof raw === "object" ? raw : {}),
    enabled: Boolean(raw?.enabled ?? previous.enabled),
  };
}

function unwrapServerState(raw) {
  if (!raw || typeof raw !== "object") return {};
  if (raw.state && typeof raw.state === "object") {
    return {
      ...raw.state,
      revision: raw.revision ?? raw.state.revision,
    };
  }
  return raw;
}

export function normalizeServerState(raw, previous = createInitialState()) {
  const source = unwrapServerState(raw);
  const audio = source.audio ?? {};
  const deviceSource = source.devices ?? audio.devices ?? {};
  const selectionSource = audio.selection !== undefined
    ? audio.selection
    : source.selection !== undefined
      ? source.selection
      : undefined;
  const engineSource = source.engine ?? audio.engine ?? {};
  const recording = normalizeSimpleEnabled(source.recording, previous.recording);
  const radio = normalizeSimpleEnabled(source.radio, previous.radio);
  const monitor = normalizeSimpleEnabled(source.monitor ?? source.monitorEnabled, previous.monitor);
  const telemetry = source.telemetry ?? source.diagnostics ?? {};

  return {
    ...previous,
    authenticated: true,
    hasSnapshot: true,
    revision: Math.max(0, Math.trunc(finite(source.revision, previous.revision))),
    engine: normalizeEngine(engineSource, previous.engine),
    devices: normalizeDevices(deviceSource, previous.devices),
    selection: normalizeSelection(selectionSource, previous.selection),
    monitor: {
      enabled: Boolean(monitor.enabled),
    },
    processing: normalizeProcessing(source.processing, previous.processing),
    equalizer: normalizeEqualizer(source.equalizer, previous.equalizer),
    radio: {
      enabled: Boolean(radio.enabled),
      listenerCount: Math.max(0, Math.trunc(finite(
        radio.listenerCount ?? radio.listeners,
        previous.radio.listenerCount,
      ))),
      url: String(radio.url ?? previous.radio.url),
    },
    recording: {
      enabled: Boolean(recording.enabled ?? recording.active),
      durationSeconds: Math.max(0, finite(
        recording.durationSeconds ?? recording.duration,
        previous.recording.durationSeconds,
      )),
      fileName: recording.fileName === null
        ? null
        : String(recording.fileName ?? recording.filename ?? previous.recording.fileName ?? "") || null,
    },
    telemetry: {
      droppedFrames: Math.max(0, Math.trunc(finite(
        telemetry.droppedFrames ?? telemetry.drops ?? telemetry.queueDrops,
        previous.telemetry.droppedFrames,
      ))),
      xruns: Math.max(0, Math.trunc(finite(telemetry.xruns, previous.telemetry.xruns))),
    },
    meters: source.meters
      ? normalizeMeters(source.meters, previous.meters)
      : previous.meters,
    error: null,
  };
}

function normalizeMeters(payload, previous) {
  const source = payload ?? {};
  const left = finite(source.left, previous.left);
  const right = finite(source.right, previous.right);
  const toDecibels = (value) => {
    if (value < 0) return clamp(value, -60, 0);
    if (value <= 1) return clamp(20 * Math.log10(Math.max(value, 0.001)), -60, 0);
    return clamp(value, -60, 0);
  };
  return {
    sequence: Math.trunc(finite(source.sequence, previous.sequence + 1)),
    left,
    right,
    leftDB: source.leftDB !== undefined ? finite(source.leftDB, -60) : toDecibels(left),
    rightDB: source.rightDB !== undefined ? finite(source.rightDB, -60) : toDecibels(right),
    peak: finite(source.peak, Math.max(left, right)),
    timestamp: source.timestamp ?? previous.timestamp,
  };
}

export function reducer(state, action) {
  switch (action.type) {
    case "CONNECTION": {
      const connection = CONNECTION_STATES.has(action.status) ? action.status : state.connection;
      return { ...state, connection };
    }
    case "PAIRING_START":
      return {
        ...state,
        pairing: { busy: true, error: "" },
        error: null,
      };
    case "PAIRING_ERROR":
      return {
        ...state,
        pairing: { busy: false, error: String(action.message ?? "Pairing failed.") },
      };
    case "AUTH_REQUIRED": {
      const initial = createInitialState();
      return {
        ...initial,
        connection: action.connection ?? "disconnected",
        pairing: {
          busy: false,
          error: String(action.message ?? ""),
        },
      };
    }
    case "SNAPSHOT": {
      const raw = unwrapServerState(action.payload);
      const revision = Math.max(0, Math.trunc(finite(raw.revision, state.revision)));
      if (state.hasSnapshot && revision <= state.revision) return state;
      return {
        ...normalizeServerState(raw, state),
        connection: state.connection,
        pairing: { busy: false, error: "" },
        pending: {},
      };
    }
    case "BASELINE":
      return {
        ...normalizeServerState(action.payload, state),
        connection: state.connection,
        pairing: { busy: false, error: "" },
        pending: {},
      };
    case "STATE_PATCH": {
      const raw = unwrapServerState(action.payload);
      const revision = Math.max(0, Math.trunc(finite(raw.revision, state.revision)));
      if (state.hasSnapshot && revision <= state.revision) return state;
      return {
        ...normalizeServerState(raw, state),
        connection: state.connection,
        pending: {},
      };
    }
    case "METERS": {
      const meters = normalizeMeters(action.payload, state.meters);
      if (meters.sequence <= state.meters.sequence) return state;
      return { ...state, meters };
    }
    case "SPECTROGRAM": {
      const sequence = Math.trunc(finite(action.payload?.sequence, state.spectrogram.sequence + 1));
      if (sequence <= state.spectrogram.sequence) return state;
      return {
        ...state,
        spectrogram: {
          ...state.spectrogram,
          sequence,
          timestamp: action.payload?.timestamp ?? state.spectrogram.timestamp,
          intensities: action.payload?.intensities ?? null,
        },
      };
    }
    case "SPECTROGRAM_PAUSED":
      return {
        ...state,
        spectrogram: { ...state.spectrogram, paused: Boolean(action.paused) },
      };
    case "MUTATION_START":
      return {
        ...state,
        pending: { ...state.pending, [action.key]: true },
        error: null,
      };
    case "MUTATION_END": {
      const pending = { ...state.pending };
      delete pending[action.key];
      return { ...state, pending };
    }
    case "ERROR":
      return {
        ...state,
        error: {
          title: String(action.error?.title ?? "Something went wrong"),
          detail: String(action.error?.detail ?? action.error?.message ?? action.error ?? "Please try again."),
          status: action.error?.status ?? null,
        },
      };
    case "CLEAR_ERROR":
      return { ...state, error: null };
    default:
      return state;
  }
}

export const pairingCode = process.env.PHONOFLOW_PAIRING_CODE ?? "123456";

export function createFixtureState() {
  return {
    apiVersion: "v1",
    revision: 1,
    generatedAt: "2026-07-24T12:00:00.000Z",
    engine: {
      phase: "running",
      format: {
        sampleRate: 48_000,
        channelCount: 2,
        bufferFrameCount: 256
      },
      problem: null
    },
    devices: [
      {
        uid: "focusrite-scarlett-2i2",
        name: "Scarlett 2i2 USB",
        inputChannelCount: 4,
        outputChannelCount: 2,
        inputRoutes: [
          { id: "channels-1-2", label: "Analog Inputs 1–2", channels: [0, 1] },
          { id: "channels-3-4", label: "Loopback Inputs 3–4", channels: [2, 3] }
        ],
        supportedSampleRates: [44_100, 48_000, 96_000, 192_000],
        transport: "usb",
        connectionState: "connected"
      },
      {
        uid: "macbook-mic",
        name: "MacBook Microphone",
        inputChannelCount: 1,
        outputChannelCount: 0,
        inputRoutes: [
          { id: "mono", label: "Input 1 (dual mono)", channels: [0, 0] }
        ],
        supportedSampleRates: [48_000],
        transport: "builtIn",
        connectionState: "connected"
      },
      {
        uid: "built-in-output",
        name: "MacBook Speakers",
        inputChannelCount: 0,
        outputChannelCount: 2,
        inputRoutes: [],
        supportedSampleRates: [48_000],
        transport: "builtIn",
        connectionState: "connected"
      }
    ],
    selection: {
      inputUID: "focusrite-scarlett-2i2",
      inputRouteID: "channels-1-2",
      outputUID: "built-in-output"
    },
    meters: {
      left: 0,
      right: 0,
      peak: 0,
      sequence: 0,
      timestamp: "2026-07-24T12:00:00.000Z"
    },
    monitor: { enabled: false },
    processing: {
      gain: 1,
      autoGainEnabled: false,
      enabled: true
    },
    equalizer: {
      enabled: true,
      bands: [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        .map((frequencyHz) => ({ frequencyHz, gainDB: 0 }))
    },
    radio: {
      enabled: false,
      listenerCount: 0,
      url: "/stream"
    },
    recording: {
      enabled: false,
      durationSeconds: 0,
      fileName: null
    },
    diagnostics: {
      callbackDurationMicroseconds: 0,
      xruns: 0,
      ringOverflows: 0,
      ringUnderflows: 0,
      queueDepth: 0,
      queueDrops: 0,
      fftLatencyMilliseconds: 0,
      renderSkips: 0,
      imageAgeMilliseconds: 0,
      memoryBytes: 0
    }
  };
}

export const spectrumColumn = {
  sequence: 1,
  timestamp: "2026-07-24T12:00:00.000Z",
  intensities: Array.from({ length: 64 }, (_, index) => index * 4)
};

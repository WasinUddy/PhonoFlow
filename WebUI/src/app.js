import { ApiProblem, EventStream, PhonoFlowAPI } from "./api.js";
import { createInitialState, decibelsToLinearGain, reducer } from "./state.js";
import { decodeIntensityColumn } from "./spectrogram.js";
import {
  DashboardView,
  formatDecibels,
  formatDecibelsSpeech,
  formatGain,
  formatGainSpeech,
} from "./view.js";

const api = new PhonoFlowAPI();
const events = new EventStream();
const view = new DashboardView(document);
let state = createInitialState();
let verifyingSession = false;

function dispatch(action) {
  const next = reducer(state, action);
  if (next === state) return;
  state = next;
  view.render(state, action);
}

function errorModel(error) {
  if (error instanceof ApiProblem) {
    return {
      title: error.title,
      detail: error.detail || "The Mac rejected this request.",
      status: error.status,
    };
  }
  return {
    title: error?.name === "NetworkError" ? "Connection unavailable" : "Request failed",
    detail: error?.message ?? "Please try again.",
  };
}

function requirePairing(message = "Your session ended. Pair this browser again.") {
  events.stop();
  view.stopAudioPlayer();
  dispatch({ type: "AUTH_REQUIRED", message });
}

function applyServerResponse(payload, type = "STATE_PATCH") {
  if (!payload || typeof payload !== "object") return false;
  const candidate = payload.state && typeof payload.state === "object"
    ? { ...payload.state, revision: payload.revision ?? payload.state.revision }
    : payload;
  if (candidate.revision === undefined && !candidate.engine && !candidate.audio && !candidate.devices) {
    return false;
  }
  dispatch({ type, payload: candidate });
  return true;
}

async function refreshAuthoritativeState({ restartEvents = false, forceBaseline = false } = {}) {
  const payload = await api.getState();
  applyServerResponse(payload, forceBaseline ? "BASELINE" : "SNAPSHOT");
  if (restartEvents) connectEvents();
}

async function restoreAfterReconnect() {
  try {
    await refreshAuthoritativeState({ forceBaseline: true });
  } catch (error) {
    if (error instanceof ApiProblem && error.status === 401) requirePairing();
  }
}

async function verifySession() {
  if (verifyingSession || !state.authenticated) return;
  verifyingSession = true;
  try {
    const payload = await api.getState();
    applyServerResponse(payload, "STATE_PATCH");
  } catch (error) {
    if (error instanceof ApiProblem && error.status === 401) {
      requirePairing();
    }
  } finally {
    verifyingSession = false;
  }
}

function handleEvent({ type, payload }) {
  switch (type) {
    case "snapshot":
      dispatch({ type: "SNAPSHOT", payload });
      break;
    case "state":
      dispatch({ type: "STATE_PATCH", payload });
      break;
    case "meters":
    case "meter":
      dispatch({ type: "METERS", payload });
      break;
    case "spectrogram":
    case "spectrum":
      try {
        dispatch({
          type: "SPECTROGRAM",
          payload: {
            ...payload,
            intensities: decodeIntensityColumn(payload?.intensities ?? payload?.column),
          },
        });
      } catch {
        // A malformed high-rate visualization event must not interrupt controls.
      }
      break;
    case "problem":
      if (Number(payload?.status) === 401) requirePairing();
      else dispatch({ type: "ERROR", error: payload });
      break;
    default:
      break;
  }
}

function connectEvents() {
  events.start({
    onConnection(status) {
      const needsFreshBaseline = status === "connected"
        && ["reconnecting", "disconnected"].includes(state.connection);
      dispatch({ type: "CONNECTION", status });
      if (needsFreshBaseline) void restoreAfterReconnect();
      if (status === "reconnecting") void verifySession();
    },
    onEvent: handleEvent,
  });
}

async function bootstrap() {
  view.render(state);
  try {
    const payload = await api.getState();
    dispatch({ type: "CONNECTION", status: "connected" });
    dispatch({ type: "SNAPSHOT", payload });
    connectEvents();
  } catch (error) {
    if (error instanceof ApiProblem && error.status === 401) {
      requirePairing("");
      return;
    }
    dispatch({ type: "CONNECTION", status: "disconnected" });
    dispatch({ type: "ERROR", error: errorModel(error) });
  }
}

async function mutate(key, operation) {
  if (state.pending[key]) return;
  dispatch({ type: "MUTATION_START", key });
  try {
    const payload = await operation();
    const applied = applyServerResponse(payload);
    if (!applied) await refreshAuthoritativeState();
  } catch (error) {
    if (error instanceof ApiProblem && error.status === 401) {
      requirePairing();
      return;
    }
    if (error instanceof ApiProblem && error.status === 409) {
      try {
        await refreshAuthoritativeState();
      } catch {
        // Preserve the original conflict as the actionable message.
      }
    }
    dispatch({ type: "ERROR", error: errorModel(error) });
  } finally {
    dispatch({ type: "MUTATION_END", key });
  }
}

view.elements["pairing-code"].addEventListener("input", (event) => {
  const input = event.currentTarget;
  input.value = input.value.replace(/[^0-9]/g, "").slice(0, 6);
  if (state.pairing.error) dispatch({ type: "PAIRING_ERROR", message: "" });
});

view.elements["pairing-form"].addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = view.elements["pairing-code"].value;
  if (!/^[0-9]{6}$/.test(code)) {
    dispatch({ type: "PAIRING_ERROR", message: "Enter all six digits from PhonoFlow Settings." });
    view.elements["pairing-code"].focus();
    return;
  }

  dispatch({ type: "PAIRING_START" });
  try {
    await api.pair(code);
    view.elements["pairing-code"].value = "";
    dispatch({ type: "CONNECTION", status: "connected" });
    await refreshAuthoritativeState({ restartEvents: true });
  } catch (error) {
    const message = error instanceof ApiProblem && error.status === 429
      ? "Too many attempts. Wait before trying another code."
      : error instanceof ApiProblem && [401, 403, 422].includes(error.status)
        ? error.detail || "That code is invalid or expired."
        : error.message || "Could not pair with this Mac.";
    dispatch({ type: "PAIRING_ERROR", message });
  }
});

view.elements["logout-button"].addEventListener("click", async () => {
  try {
    await api.logout();
  } catch (error) {
    if (!(error instanceof ApiProblem && error.status === 401)) {
      dispatch({ type: "ERROR", error: errorModel(error) });
      return;
    }
  }
  requirePairing("Logged out. Enter a new pairing code to reconnect.");
});

view.elements["dismiss-error"].addEventListener("click", () => {
  dispatch({ type: "CLEAR_ERROR" });
});

view.elements["refresh-devices"].addEventListener("click", () => {
  void mutate("refreshDevices", () => api.refreshDevices());
});

function selectionFromControls() {
  return {
    inputUID: view.elements["input-device"].value || null,
    inputRouteID: view.elements["input-route"].value || null,
    outputUID: view.elements["output-device"].value || null,
  };
}

view.elements["input-device"].addEventListener("change", () => {
  const selected = state.devices.inputs.find(
    (device) => device.uid === view.elements["input-device"].value,
  );
  const selection = selectionFromControls();
  selection.inputRouteID = selected?.inputRoutes[0]?.id ?? null;
  void mutate("selection", () => api.updateSelection(selection));
});

view.elements["input-route"].addEventListener("change", () => {
  void mutate("selection", () => api.updateSelection(selectionFromControls()));
});

view.elements["output-device"].addEventListener("change", () => {
  void mutate("selection", () => api.updateSelection(selectionFromControls()));
});

view.elements["monitor-toggle"].addEventListener("click", () => {
  void mutate("monitor", () => api.updateMonitor(!state.monitor.enabled));
});

view.elements["radio-toggle"].addEventListener("click", () => {
  void mutate("radio", () => api.updateRadio(!state.radio.enabled));
});

view.elements["recording-toggle"].addEventListener("click", () => {
  void mutate("recording", () => api.updateRecording(!state.recording.enabled));
});

view.elements["gain-control"].addEventListener("input", (event) => {
  const value = Number(event.currentTarget.value);
  view.elements["gain-output"].textContent = formatGain(value);
  event.currentTarget.setAttribute("aria-valuetext", formatGainSpeech(value));
});

view.elements["gain-control"].addEventListener("change", (event) => {
  const gainDB = Number(event.currentTarget.value);
  void mutate("processing", () => api.updateProcessing({
    gain: decibelsToLinearGain(gainDB),
  }));
});

view.elements["auto-gain-toggle"].addEventListener("click", () => {
  void mutate("processing", () => api.updateProcessing({
    autoGainEnabled: !state.processing.autoGainEnabled,
  }));
});

for (const [index, input] of view.eqInputs.entries()) {
  input.addEventListener("input", (event) => {
    const value = Number(event.currentTarget.value);
    const label = formatDecibels(value);
    view.eqOutputs[index].textContent = label;
    event.currentTarget.setAttribute("aria-valuetext", formatDecibelsSpeech(value));
  });
  input.addEventListener("change", (event) => {
    const bands = state.equalizer.bands.map((band, bandIndex) => ({
      ...band,
      gainDB: bandIndex === index ? Number(event.currentTarget.value) : band.gainDB,
    }));
    void mutate("equalizer", () => api.updateEqualizer(bands));
  });
}

view.elements["reset-eq"].addEventListener("click", () => {
  const bands = state.equalizer.bands.map((band) => ({ ...band, gainDB: 0 }));
  void mutate("equalizer", () => api.updateEqualizer(bands));
});

view.elements["spectrum-toggle"].addEventListener("click", () => {
  dispatch({ type: "SPECTROGRAM_PAUSED", paused: !state.spectrogram.paused });
  view.announce(state.spectrogram.paused ? "Spectrogram paused." : "Spectrogram resumed.");
});

view.elements["prepare-audio"].addEventListener("click", async () => {
  try {
    await view.showAudioPlayer();
  } catch {
    // Browsers may require the user to press the native play control after loading.
    view.announce("Live audio is ready. Use the audio play control to begin.");
  }
});

view.elements["live-audio"].addEventListener("error", () => {
  dispatch({
    type: "ERROR",
    error: {
      title: "Browser playback unavailable",
      detail: "Check capture, the audio engine, and this browser’s connection to the Mac.",
    },
  });
});

window.addEventListener("beforeunload", () => events.stop(), { once: true });

void bootstrap();

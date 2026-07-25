import { EQ_FREQUENCIES } from "./state.js";
import { SpectrogramRenderer } from "./spectrogram.js";

const text = (value, fallback = "—") => {
  if (value === null || value === undefined || value === "") return fallback;
  return String(value);
};

const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, Number(value) || 0));

export function formatDecibels(value) {
  const number = clamp(value, -96, 96);
  if (number === 0) return "0.0 dB";
  const prefix = number > 0 ? "+" : "−";
  return `${prefix}${Math.abs(number).toFixed(1)} dB`;
}

export function formatDecibelsSpeech(value) {
  const number = clamp(value, -96, 96);
  if (number === 0) return "0 decibels";
  const prefix = number > 0 ? "plus" : "minus";
  return `${prefix} ${Math.abs(number).toFixed(1).replace(/\.0$/, "")} decibels`;
}

export function formatGain(value) {
  return Number(value) <= -60 ? "Muted" : formatDecibels(value);
}

export function formatGainSpeech(value) {
  return Number(value) <= -60 ? "muted" : formatDecibelsSpeech(value);
}

function frequencyLabel(frequencyHz) {
  if (frequencyHz >= 1_000) {
    const value = frequencyHz / 1_000;
    return `${Number.isInteger(value) ? value : value.toFixed(1)}k`;
  }
  return String(frequencyHz);
}

function formatDuration(seconds) {
  const whole = Math.max(0, Math.floor(Number(seconds) || 0));
  const minutes = Math.floor(whole / 60);
  const remainder = whole % 60;
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function formatEngineState(value) {
  const labels = {
    idle: "Idle",
    starting: "Starting",
    running: "Running",
    disconnected: "Disconnected",
    failed: "Failed",
  };
  return labels[value] ?? "Unknown";
}

function formatConnection(value) {
  const labels = {
    connecting: "Connecting…",
    connected: "Connected",
    reconnecting: "Reconnecting…",
    disconnected: "Disconnected",
  };
  return labels[value] ?? "Disconnected";
}

function formatAudioFormat(format) {
  if (!format) return "—";
  const rate = Number(format.sampleRate) || 0;
  const rateLabel = rate >= 1_000
    ? `${(rate / 1_000).toFixed(rate % 1_000 === 0 ? 0 : 1)} kHz`
    : `${rate} Hz`;
  const channels = Number(format.channelCount) || 2;
  const channelLabel = channels === 1 ? "mono" : channels === 2 ? "stereo" : `${channels} ch`;
  const frames = Number(format.bufferFrames) > 0 ? ` · ${format.bufferFrames} frames` : "";
  return `${rateLabel} · ${channelLabel} · ${text(format.sampleFormat, "Float32")}${frames}`;
}

function setBusy(element, busy) {
  element.disabled = Boolean(busy);
  if (busy) element.setAttribute("aria-busy", "true");
  else element.removeAttribute("aria-busy");
}

function setSwitch(element, enabled, labelElement, onLabel = "On", offLabel = "Off") {
  element.setAttribute("aria-checked", String(Boolean(enabled)));
  if (labelElement) labelElement.textContent = enabled ? onLabel : offLabel;
}

function optionsSignature(options, selectedValue) {
  return JSON.stringify([selectedValue, options.map(({ value, label, disabled }) => [value, label, disabled])]);
}

function updateSelect(select, options, selectedValue) {
  const signature = optionsSignature(options, selectedValue);
  if (select.dataset.signature === signature) return;

  const document = select.ownerDocument;
  const fragment = document.createDocumentFragment();
  for (const item of options) {
    const option = document.createElement("option");
    option.value = item.value;
    option.textContent = item.label;
    option.disabled = Boolean(item.disabled);
    fragment.append(option);
  }
  select.replaceChildren(fragment);
  select.value = selectedValue ?? "";
  select.dataset.signature = signature;
}

function currentDevice(devices, uid) {
  return devices.find((device) => device.uid === uid) ?? null;
}

export class DashboardView {
  constructor(document) {
    this.document = document;
    this.wasAuthenticated = null;
    this.lastAnnouncement = "";
    this.elements = {};
    for (const id of [
      "connection-pill", "connection-label", "logout-button", "error-notice", "error-title",
      "error-detail", "announcer", "pairing-view", "pairing-form", "pairing-code",
      "pairing-error", "pair-button", "dashboard-view", "dashboard-title", "engine-description",
      "engine-dot", "engine-state", "engine-format", "state-revision", "input-device",
      "input-route", "output-device", "routing-note", "refresh-devices", "left-meter",
      "right-meter", "left-meter-value", "right-meter-value", "signal-badge", "monitor-toggle",
      "monitor-state", "radio-toggle", "radio-state", "recording-toggle", "recording-state",
      "listener-count", "recording-info", "spectrogram", "spectrum-summary", "spectrum-toggle",
      "auto-gain-toggle", "auto-gain-state", "gain-control", "gain-output", "prepare-audio",
      "live-audio", "eq-controls", "reset-eq", "diagnostic-connection", "diagnostic-engine",
      "diagnostic-input", "diagnostic-output", "diagnostic-drops", "diagnostic-xruns",
      "dismiss-error",
    ]) {
      this.elements[id] = document.getElementById(id);
    }
    this.buildEqualizer();
    this.spectrogram = new SpectrogramRenderer(
      this.elements.spectrogram,
      this.elements["spectrum-summary"],
    );
    this.syncCanvasSize = this.syncCanvasSize.bind(this);
    globalThis.addEventListener?.("resize", this.syncCanvasSize, { passive: true });
    globalThis.requestAnimationFrame?.(this.syncCanvasSize);
  }

  buildEqualizer() {
    const container = this.elements["eq-controls"];
    const fragment = this.document.createDocumentFragment();
    this.eqInputs = [];
    this.eqOutputs = [];

    for (const [index, frequencyHz] of EQ_FREQUENCIES.entries()) {
      const wrapper = this.document.createElement("div");
      wrapper.className = "eq-band";

      const label = this.document.createElement("label");
      label.htmlFor = `eq-band-${index}`;
      label.textContent = frequencyLabel(frequencyHz);
      label.title = `${frequencyHz.toLocaleString()} hertz`;

      const input = this.document.createElement("input");
      input.id = `eq-band-${index}`;
      input.type = "range";
      input.min = "-12";
      input.max = "12";
      input.step = "0.5";
      input.value = "0";
      input.dataset.index = String(index);
      input.setAttribute("aria-label", `${frequencyHz.toLocaleString()} hertz gain`);
      input.setAttribute("aria-valuetext", "0 decibels");

      const output = this.document.createElement("output");
      output.htmlFor = input.id;
      output.textContent = "0.0 dB";

      wrapper.append(label, input, output);
      fragment.append(wrapper);
      this.eqInputs.push(input);
      this.eqOutputs.push(output);
    }
    container.replaceChildren(fragment);
  }

  syncCanvasSize() {
    const canvas = this.elements.spectrogram;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect?.();
    if (!rect?.width || !rect?.height) return;
    const ratio = Math.min(2, Math.max(1, globalThis.devicePixelRatio || 1));
    const width = Math.round(rect.width * ratio);
    const height = Math.round(rect.height * ratio);
    if (canvas.width === width && canvas.height === height) return;
    canvas.width = width;
    canvas.height = height;
    this.spectrogram.draw();
  }

  announce(message) {
    if (!message || message === this.lastAnnouncement) return;
    this.lastAnnouncement = message;
    this.elements.announcer.textContent = message;
  }

  render(state, action = { type: "FULL" }) {
    if (action.type === "METERS") {
      this.renderMeters(state);
      return;
    }
    if (action.type === "SPECTROGRAM") {
      this.renderSpectrogram(state);
      return;
    }
    if (action.type === "SPECTROGRAM_PAUSED") {
      this.renderSpectrogramPause(state);
      return;
    }

    this.renderConnection(state);
    this.renderAuthentication(state);
    this.renderError(state);
    if (!state.authenticated) return;
    this.renderEngine(state);
    this.renderRouting(state);
    this.renderMeters(state);
    this.renderActions(state);
    this.renderProcessing(state);
    this.renderEqualizer(state);
    this.renderDiagnostics(state);
    this.renderSpectrogramPause(state);
  }

  renderConnection(state) {
    const label = formatConnection(state.connection);
    const pill = this.elements["connection-pill"];
    pill.classList.remove("is-connected", "is-reconnecting", "is-disconnected");
    pill.classList.add(`is-${state.connection}`);
    this.elements["connection-label"].textContent = label;
    this.elements["diagnostic-connection"].textContent = label.replace("…", "");
    if (state.authenticated && ["reconnecting", "disconnected"].includes(state.connection)) {
      this.announce(`${label} Last received controls remain visible.`);
    }
  }

  renderAuthentication(state) {
    const authenticated = Boolean(state.authenticated);
    this.elements["pairing-view"].hidden = authenticated;
    this.elements["dashboard-view"].hidden = !authenticated;
    this.elements["logout-button"].hidden = !authenticated;
    setBusy(this.elements["pair-button"], state.pairing.busy);
    this.elements["pair-button"].textContent = state.pairing.busy ? "Pairing…" : "Pair securely";
    this.elements["pairing-error"].textContent = state.pairing.error;
    this.elements["pairing-code"].setAttribute("aria-invalid", String(Boolean(state.pairing.error)));

    if (this.wasAuthenticated !== authenticated) {
      if (authenticated) {
        this.elements["dashboard-title"].focus();
        this.announce("Paired. Audio dashboard ready.");
      } else if (this.wasAuthenticated === true || state.pairing.error) {
        this.elements["pairing-code"].focus();
      }
      this.wasAuthenticated = authenticated;
    }
  }

  renderError(state) {
    const notice = this.elements["error-notice"];
    notice.hidden = !state.error;
    if (!state.error) return;
    this.elements["error-title"].textContent = state.error.title;
    this.elements["error-detail"].textContent = state.error.detail;
  }

  renderEngine(state) {
    const engineLabel = formatEngineState(state.engine.state);
    this.elements["engine-state"].textContent = engineLabel;
    this.elements["engine-format"].textContent = formatAudioFormat(state.engine.format);
    this.elements["state-revision"].textContent = String(state.revision);
    this.elements["engine-description"].textContent = state.engine.error?.detail
      ?? (state.engine.state === "running"
        ? "Capture is active and ready for monitoring, recording, or streaming."
        : state.engine.state === "disconnected"
          ? "The selected input is unavailable. PhonoFlow will reconnect by stable device ID."
          : state.engine.state === "failed"
            ? "The audio engine needs attention on the Mac."
            : "Waiting for the audio engine.");

    const dot = this.elements["engine-dot"];
    dot.className = `status-dot is-${state.engine.state}`;
  }

  renderRouting(state) {
    const inputOptions = state.devices.inputs.map((device) => ({
      value: device.uid,
      label: `${device.name}${device.connected ? "" : " — disconnected"}`,
      disabled: !device.connected,
    }));
    if (state.selection.inputUID && !currentDevice(state.devices.inputs, state.selection.inputUID)) {
      inputOptions.unshift({
        value: state.selection.inputUID,
        label: `Unavailable input (${state.selection.inputUID})`,
        disabled: false,
      });
    }
    if (!inputOptions.length) inputOptions.push({ value: "", label: "No input available" });

    const selectedInput = currentDevice(state.devices.inputs, state.selection.inputUID);
    const routeOptions = (selectedInput?.inputRoutes ?? []).map((route) => ({
      value: route.id,
      label: route.name,
      disabled: false,
    }));
    if (
      state.selection.inputRouteID
      && !routeOptions.some((route) => route.value === state.selection.inputRouteID)
    ) {
      routeOptions.unshift({
        value: state.selection.inputRouteID,
        label: `Unavailable route (${state.selection.inputRouteID})`,
        disabled: false,
      });
    }
    if (!routeOptions.length) routeOptions.push({ value: "", label: "No channel pair available" });

    const outputOptions = [{ value: "", label: "No output (capture only)" }];
    outputOptions.push(...state.devices.outputs.map((device) => ({
      value: device.uid,
      label: `${device.name}${device.connected ? "" : " — disconnected"}`,
      disabled: !device.connected,
    })));
    if (
      state.selection.outputUID
      && !outputOptions.some((device) => device.value === state.selection.outputUID)
    ) {
      outputOptions.unshift({
        value: state.selection.outputUID,
        label: `Unavailable output (${state.selection.outputUID})`,
        disabled: false,
      });
    }

    updateSelect(this.elements["input-device"], inputOptions, state.selection.inputUID ?? "");
    updateSelect(this.elements["input-route"], routeOptions, state.selection.inputRouteID ?? "");
    updateSelect(this.elements["output-device"], outputOptions, state.selection.outputUID ?? "");

    const selectionBusy = Boolean(state.pending.selection);
    const recording = state.recording.enabled;
    setBusy(this.elements["input-device"], selectionBusy || recording);
    setBusy(this.elements["input-route"], selectionBusy || recording || !selectedInput);
    setBusy(this.elements["output-device"], selectionBusy);
    setBusy(this.elements["refresh-devices"], Boolean(state.pending.refreshDevices));
    this.elements["routing-note"].textContent = recording
      ? "Input device and channel pair are locked until recording stops."
      : "Input changes use stable device IDs and survive reconnects.";
  }

  renderMeters(state) {
    const left = clamp(state.meters.leftDB, -60, 0);
    const right = clamp(state.meters.rightDB, -60, 0);
    const leftText = formatDecibels(left);
    const rightText = formatDecibels(right);

    this.elements["left-meter"].value = left;
    this.elements["right-meter"].value = right;
    this.elements["left-meter"].textContent = `Left channel: ${leftText}`;
    this.elements["right-meter"].textContent = `Right channel: ${rightText}`;
    this.elements["left-meter"].setAttribute("aria-valuetext", leftText);
    this.elements["right-meter"].setAttribute("aria-valuetext", rightText);
    this.elements["left-meter-value"].textContent = leftText;
    this.elements["right-meter-value"].textContent = rightText;

    const peak = Math.max(left, right);
    this.elements["signal-badge"].textContent = peak > -3
      ? "Peak warning"
      : peak > -55
        ? "Signal active"
        : "No signal";
  }

  renderActions(state) {
    setSwitch(
      this.elements["monitor-toggle"],
      state.monitor.enabled,
      this.elements["monitor-state"],
    );
    setSwitch(
      this.elements["radio-toggle"],
      state.radio.enabled,
      this.elements["radio-state"],
      "On air",
      "Off",
    );
    setSwitch(
      this.elements["recording-toggle"],
      state.recording.enabled,
      this.elements["recording-state"],
      "Recording",
      "Ready",
    );

    const engineUnavailable = state.engine.state !== "running";
    setBusy(
      this.elements["monitor-toggle"],
      Boolean(state.pending.monitor) || engineUnavailable || !state.selection.outputUID,
    );
    setBusy(this.elements["radio-toggle"], Boolean(state.pending.radio) || engineUnavailable);
    setBusy(this.elements["recording-toggle"], Boolean(state.pending.recording) || engineUnavailable);

    this.elements["listener-count"].textContent = state.radio.listenerCount.toLocaleString();
    this.elements["recording-info"].textContent = state.recording.enabled
      ? `${formatDuration(state.recording.durationSeconds)}${state.recording.fileName ? ` · ${state.recording.fileName}` : ""}`
      : "Not recording";
  }

  renderProcessing(state) {
    setSwitch(
      this.elements["auto-gain-toggle"],
      state.processing.autoGainEnabled,
      this.elements["auto-gain-state"],
    );
    setBusy(this.elements["auto-gain-toggle"], Boolean(state.pending.processing));
    setBusy(
      this.elements["gain-control"],
      Boolean(state.pending.processing) || state.processing.autoGainEnabled,
    );
    if (this.document.activeElement !== this.elements["gain-control"]) {
      this.elements["gain-control"].value = String(state.processing.gainDB);
    }
    const label = formatGain(state.processing.gainDB);
    this.elements["gain-output"].textContent = label;
    this.elements["gain-control"].setAttribute(
      "aria-valuetext",
      formatGainSpeech(state.processing.gainDB),
    );
  }

  renderEqualizer(state) {
    for (const [index, input] of this.eqInputs.entries()) {
      const value = state.equalizer.bands[index]?.gainDB ?? 0;
      if (this.document.activeElement !== input) input.value = String(value);
      const label = formatDecibels(value);
      this.eqOutputs[index].textContent = label;
      input.setAttribute("aria-valuetext", formatDecibelsSpeech(value));
      input.disabled = Boolean(state.pending.equalizer);
    }
    setBusy(this.elements["reset-eq"], Boolean(state.pending.equalizer));
  }

  renderSpectrogram(state) {
    if (state.spectrogram.paused || !state.spectrogram.intensities) return;
    this.spectrogram.add(
      state.spectrogram.intensities,
      state.spectrogram.sequence,
      state.spectrogram.timestamp,
    );
  }

  renderSpectrogramPause(state) {
    const paused = Boolean(state.spectrogram.paused);
    this.elements["spectrum-toggle"].setAttribute("aria-pressed", String(paused));
    this.elements["spectrum-toggle"].textContent = paused ? "Resume" : "Pause";
    this.spectrogram.setPaused(paused);
  }

  renderDiagnostics(state) {
    const input = currentDevice(state.devices.inputs, state.selection.inputUID);
    const output = currentDevice(state.devices.outputs, state.selection.outputUID);
    this.elements["diagnostic-engine"].textContent = formatEngineState(state.engine.state);
    this.elements["diagnostic-input"].textContent = input?.name ?? "None";
    this.elements["diagnostic-output"].textContent = output?.name ?? "Capture only";
    this.elements["diagnostic-drops"].textContent = state.telemetry.droppedFrames.toLocaleString();
    this.elements["diagnostic-xruns"].textContent = state.telemetry.xruns.toLocaleString();
  }

  showAudioPlayer() {
    const audio = this.elements["live-audio"];
    if (!audio.getAttribute("src")) audio.setAttribute("src", "/audio/live.wav");
    audio.hidden = false;
    this.elements["prepare-audio"].hidden = true;
    audio.load?.();
    return audio.play?.();
  }

  stopAudioPlayer() {
    const audio = this.elements["live-audio"];
    audio.pause?.();
    audio.removeAttribute("src");
    audio.load?.();
    audio.hidden = true;
    this.elements["prepare-audio"].hidden = false;
  }
}

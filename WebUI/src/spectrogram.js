const ROW_COUNT = 64;
const COLUMN_COUNT = 64;

const clampByte = (value) => Math.min(255, Math.max(0, Math.round(Number(value) || 0)));

function calculateIntensityColor(value) {
  const normalized = value / 255;
  let red;
  let green;
  let blue;

  if (normalized < 0.35) {
    const amount = normalized / 0.35;
    red = 3 + (9 * amount);
    green = 9 + (62 * amount);
    blue = 16 + (111 * amount);
  } else if (normalized < 0.72) {
    const amount = (normalized - 0.35) / 0.37;
    red = 12 + (65 * amount);
    green = 71 + (164 * amount);
    blue = 127 + (49 * amount);
  } else {
    const amount = (normalized - 0.72) / 0.28;
    red = 77 + (178 * amount);
    green = 235 - (56 * amount);
    blue = 176 - (91 * amount);
  }

  return [Math.round(red), Math.round(green), Math.round(blue), 255];
}

const COLOR_LUT = new Uint8ClampedArray(256 * 4);
for (let intensity = 0; intensity < 256; intensity += 1) {
  const color = calculateIntensityColor(intensity);
  COLOR_LUT.set(color, intensity * 4);
}

export function decodeIntensityColumn(value) {
  if (value instanceof Uint8Array) {
    if (value.length !== ROW_COUNT) throw new RangeError("A spectrogram column must contain 64 values.");
    return value;
  }

  if (Array.isArray(value)) {
    if (value.length !== ROW_COUNT) throw new RangeError("A spectrogram column must contain 64 values.");
    return Uint8Array.from(value, clampByte);
  }

  if (typeof value === "string") {
    let binary;
    try {
      binary = globalThis.atob
        ? globalThis.atob(value)
        : Buffer.from(value, "base64").toString("binary");
    } catch {
      throw new TypeError("The spectrogram column is not valid base64.");
    }
    if (binary.length !== ROW_COUNT) throw new RangeError("A spectrogram column must contain 64 values.");
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  throw new TypeError("Unsupported spectrogram column.");
}

export function intensityColor(value) {
  const offset = clampByte(value) * 4;
  return Array.from(COLOR_LUT.subarray(offset, offset + 4));
}

export class SpectrogramHistory {
  constructor(size = COLUMN_COUNT) {
    this.size = Math.max(1, Math.trunc(Number(size) || COLUMN_COUNT));
    this.buffer = new Uint8Array(this.size * ROW_COUNT);
    this.count = 0;
    this.writeIndex = 0;
    this.lastSequence = -1;
  }

  push(column, sequence) {
    const nextSequence = Number.isFinite(Number(sequence))
      ? Math.trunc(Number(sequence))
      : this.lastSequence + 1;
    if (nextSequence <= this.lastSequence) return false;
    const decoded = decodeIntensityColumn(column);
    this.buffer.set(decoded, this.writeIndex * ROW_COUNT);
    this.writeIndex = (this.writeIndex + 1) % this.size;
    this.count = Math.min(this.size, this.count + 1);
    this.lastSequence = nextSequence;
    return true;
  }

  columnAt(index) {
    if (index < 0 || index >= this.count) return null;
    const oldestSlot = this.count < this.size ? 0 : this.writeIndex;
    const slot = (oldestSlot + index) % this.size;
    return this.buffer.subarray(slot * ROW_COUNT, (slot + 1) * ROW_COUNT);
  }

  get columns() {
    return Array.from({ length: this.count }, (_, index) => this.columnAt(index));
  }

  reset() {
    this.count = 0;
    this.writeIndex = 0;
    this.lastSequence = -1;
  }
}

function peakSummary(column) {
  let peakIndex = 0;
  let peakValue = 0;
  for (let index = 0; index < column.length; index += 1) {
    if (column[index] > peakValue) {
      peakValue = column[index];
      peakIndex = index;
    }
  }
  const frequency = 20 * (1_000 ** (peakIndex / (ROW_COUNT - 1)));
  const frequencyLabel = frequency >= 1_000
    ? `${(frequency / 1_000).toFixed(frequency >= 10_000 ? 0 : 1)} kHz`
    : `${Math.round(frequency)} Hz`;
  const decibels = -96 + (peakValue / 255) * 96;
  return `Peak ${frequencyLabel} at ${decibels.toFixed(0)} dB.`;
}

export class SpectrogramRenderer {
  constructor(canvas, summaryElement) {
    this.canvas = canvas;
    this.summaryElement = summaryElement;
    this.history = new SpectrogramHistory();
    this.context = null;
    this.bufferCanvas = null;
    this.bufferContext = null;
    this.imageData = null;
    this.paused = false;

    try {
      this.context = canvas?.getContext?.("2d", { alpha: false }) ?? null;
      this.bufferCanvas = canvas?.ownerDocument?.createElement?.("canvas") ?? null;
      if (this.bufferCanvas) {
        this.bufferCanvas.width = COLUMN_COUNT;
        this.bufferCanvas.height = ROW_COUNT;
        this.bufferContext = this.bufferCanvas.getContext?.("2d", { alpha: false }) ?? null;
        this.imageData = this.bufferContext?.createImageData?.(COLUMN_COUNT, ROW_COUNT) ?? null;
      }
    } catch {
      this.context = null;
      this.bufferContext = null;
    }
  }

  setPaused(paused) {
    this.paused = Boolean(paused);
    if (this.summaryElement && this.paused) {
      this.summaryElement.textContent = "Visualization paused. Audio controls remain active.";
    }
  }

  add(column, sequence, timestamp) {
    if (this.paused) return false;
    let decoded;
    try {
      decoded = decodeIntensityColumn(column);
    } catch {
      return false;
    }
    if (!this.history.push(decoded, sequence)) return false;
    if (this.summaryElement) {
      const time = timestamp ? ` Updated ${new Date(timestamp).toLocaleTimeString()}.` : "";
      this.summaryElement.textContent = `${peakSummary(decoded)}${time}`;
    }
    this.draw();
    return true;
  }

  draw() {
    if (!this.context || !this.bufferContext || !this.bufferCanvas || !this.canvas) return;
    if (!this.imageData) return;
    const emptyOffset = COLUMN_COUNT - this.history.count;
    const pixels = this.imageData.data;

    for (let x = 0; x < COLUMN_COUNT; x += 1) {
      const column = x >= emptyOffset ? this.history.columnAt(x - emptyOffset) : null;
      for (let row = 0; row < ROW_COUNT; row += 1) {
        const intensity = column ? column[row] : 0;
        const colorOffset = intensity * 4;
        const y = ROW_COUNT - row - 1;
        const offset = (y * COLUMN_COUNT + x) * 4;
        pixels[offset] = COLOR_LUT[colorOffset];
        pixels[offset + 1] = COLOR_LUT[colorOffset + 1];
        pixels[offset + 2] = COLOR_LUT[colorOffset + 2];
        pixels[offset + 3] = 255;
      }
    }

    this.bufferContext.putImageData(this.imageData, 0, 0);
    this.context.imageSmoothingEnabled = false;
    this.context.drawImage(this.bufferCanvas, 0, 0, this.canvas.width, this.canvas.height);
  }

  reset() {
    this.history.reset();
    this.context?.clearRect?.(0, 0, this.canvas?.width ?? 0, this.canvas?.height ?? 0);
    if (this.summaryElement) this.summaryElement.textContent = "Waiting for spectrum data.";
  }
}

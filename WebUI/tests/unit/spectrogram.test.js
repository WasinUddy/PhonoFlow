import { describe, expect, it } from "vitest";
import {
  SpectrogramHistory,
  SpectrogramRenderer,
  decodeIntensityColumn,
  intensityColor,
} from "../../src/spectrogram.js";

describe("spectrogram model", () => {
  it("decodes arrays and exact 64-byte base64 columns", () => {
    const source = Uint8Array.from({ length: 64 }, (_, index) => index * 4);
    const base64 = Buffer.from(source).toString("base64");
    expect(Array.from(decodeIntensityColumn(base64))).toEqual(Array.from(source));
    expect(Array.from(decodeIntensityColumn(Array.from(source)))).toEqual(Array.from(source));
    expect(decodeIntensityColumn(source)).toBe(source);
    expect(() => decodeIntensityColumn([1, 2])).toThrow("64");
  });

  it("clamps deterministic color endpoints", () => {
    expect(intensityColor(-50)).toEqual(intensityColor(0));
    expect(intensityColor(999)).toEqual(intensityColor(255));
    expect(intensityColor(0)).toEqual([3, 9, 16, 255]);
    expect(intensityColor(255)).toEqual([255, 179, 85, 255]);
  });

  it("maintains chronological bounded history and ignores old sequences", () => {
    const history = new SpectrogramHistory(3);
    for (let sequence = 1; sequence <= 4; sequence += 1) {
      history.push(Array(64).fill(sequence), sequence);
    }
    expect(history.columns).toHaveLength(3);
    expect(history.columns.map((column) => column[0])).toEqual([2, 3, 4]);
    expect(history.push(Array(64).fill(9), 4)).toBe(false);
    expect(history.columns.map((column) => column[0])).toEqual([2, 3, 4]);
    history.reset();
    expect(history.columns).toEqual([]);
    expect(history.lastSequence).toBe(-1);
  });

  it("reuses one image buffer across continuous renderer updates", () => {
    let imageAllocations = 0;
    let paints = 0;
    const bufferContext = {
      createImageData(width, height) {
        imageAllocations += 1;
        return { data: new Uint8ClampedArray(width * height * 4) };
      },
      putImageData() {
        paints += 1;
      },
    };
    const targetContext = {
      imageSmoothingEnabled: true,
      drawImage() {},
      clearRect() {},
    };
    const canvas = {
      width: 640,
      height: 256,
      getContext: () => targetContext,
      ownerDocument: {
        createElement: () => ({
          width: 0,
          height: 0,
          getContext: () => bufferContext,
        }),
      },
    };
    const summary = { textContent: "" };
    const renderer = new SpectrogramRenderer(canvas, summary);
    renderer.add(Uint8Array.from({ length: 64 }, (_, index) => index), 1);
    renderer.add(Uint8Array.from({ length: 64 }, (_, index) => 255 - index), 2);

    expect(imageAllocations).toBe(1);
    expect(paints).toBe(2);
    expect(renderer.history.count).toBe(2);
    expect(summary.textContent).toContain("Peak");
  });
});

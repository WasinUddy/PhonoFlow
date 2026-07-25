import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

const externalServer = process.env.PHONOFLOW_E2E_EXTERNAL_SERVER === "1";

async function openAuthenticatedDashboard(page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Your sound, in flow." })).toBeVisible();
  await expect(page.locator("#connection-label")).toHaveText("Connected");
}

async function setSwitch(page, name, enabled) {
  const control = page.getByRole("switch", { name });
  if (await control.getAttribute("aria-checked") !== String(enabled)) {
    await control.click();
  }
  await expect(control).toHaveAttribute("aria-checked", String(enabled));
  return control;
}

async function probeStreamingWAV(page) {
  return page.evaluate(async () => {
    const controller = new AbortController();
    const response = await fetch("/audio/live.wav", {
      credentials: "same-origin",
      signal: controller.signal,
    });
    const reader = response.body?.getReader();
    if (!reader) throw new Error("The live WAV response did not expose a readable body.");

    const requiredByteCount = 4_140; // Header plus 1,024 stereo PCM16 frames.
    const bytes = [];
    try {
      while (bytes.length < requiredByteCount) {
        let timer;
        const result = await Promise.race([
          reader.read(),
          new Promise((_, reject) => {
            timer = setTimeout(
              () => reject(new Error("Timed out waiting for the live WAV header.")),
              5_000,
            );
          }),
        ]);
        clearTimeout(timer);
        if (result.done) break;
        for (const byte of result.value) {
          bytes.push(byte);
          if (bytes.length >= requiredByteCount) break;
        }
      }
    } finally {
      await reader.cancel().catch(() => {});
      controller.abort();
    }

    const header = Uint8Array.from(bytes);
    const view = header.length >= 44
      ? new DataView(header.buffer, header.byteOffset, header.byteLength)
      : null;
    const ascii = (start, end) => String.fromCharCode(...header.slice(start, end));
    const payloadByteCount = Math.max(0, header.byteLength - 44);
    const frameAlignedPayloadByteCount = payloadByteCount - (payloadByteCount % 4);
    const decodableWAV = header.slice(0, 44 + frameAlignedPayloadByteCount);
    const decodableView = new DataView(
      decodableWAV.buffer,
      decodableWAV.byteOffset,
      decodableWAV.byteLength,
    );
    decodableView.setUint32(4, 36 + frameAlignedPayloadByteCount, true);
    decodableView.setUint32(40, frameAlignedPayloadByteCount, true);

    const AudioContextConstructor = globalThis.AudioContext
      ?? globalThis.webkitAudioContext;
    if (!AudioContextConstructor) {
      throw new Error("This browser does not expose an audio decoder.");
    }
    const audioContext = new AudioContextConstructor();
    let decoded;
    try {
      decoded = await audioContext.decodeAudioData(decodableWAV.buffer.slice(0));
    } finally {
      await audioContext.close();
    }
    let decodedPeak = 0;
    for (let channel = 0; channel < decoded.numberOfChannels; channel += 1) {
      for (const sample of decoded.getChannelData(channel)) {
        decodedPeak = Math.max(decodedPeak, Math.abs(sample));
      }
    }

    return {
      status: response.status,
      contentType: response.headers.get("content-type") ?? "",
      byteLength: header.byteLength,
      riff: ascii(0, 4),
      wave: ascii(8, 12),
      formatChunk: ascii(12, 16),
      dataChunk: ascii(36, 40),
      formatCode: view?.getUint16(20, true) ?? 0,
      channelCount: view?.getUint16(22, true) ?? 0,
      sampleRate: view?.getUint32(24, true) ?? 0,
      bitsPerSample: view?.getUint16(34, true) ?? 0,
      dataByteCount: view?.getUint32(40, true) ?? 0,
      nonZeroPayloadBytes: header.slice(44).filter((byte) => byte !== 0).length,
      payloadByteCount,
      decodedChannels: decoded.numberOfChannels,
      decodedDuration: decoded.duration,
      decodedFrames: decoded.length,
      decodedPeak,
      decodedSampleRate: decoded.sampleRate,
    };
  });
}

test("pairing is validated and both views are accessible", async ({
  browser,
  page,
  request,
}) => {
  test.setTimeout(60_000);

  const unauthenticatedContext = await browser.newContext({
    storageState: { cookies: [], origins: [] },
  });
  const pairingPage = await unauthenticatedContext.newPage();
  await pairingPage.goto("/");
  await expect(pairingPage.getByRole("heading", { name: "Pair with this Mac" })).toBeVisible();

  const pairingResults = await new AxeBuilder({ page: pairingPage })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(pairingResults.violations.filter(({ impact }) => ["critical", "serious"].includes(impact ?? ""))).toEqual([]);

  await pairingPage.getByLabel("Pairing code").fill("000000");
  await pairingPage.getByRole("button", { name: "Pair securely" }).click();
  await expect(pairingPage.getByText(/invalid or expired/i)).toBeVisible();
  await unauthenticatedContext.close();

  if (!externalServer) {
    const statistics = await (await request.get("/__fixture__/stats")).json();
    expect(statistics.successfulPairings).toBe(1);
  }

  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Your sound, in flow." })).toBeVisible();

  const dashboardResults = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(dashboardResults.violations.filter(({ impact }) => ["critical", "serious"].includes(impact ?? ""))).toEqual([]);
});

test("routes a four-input device and reconciles remote controls", async ({ page }) => {
  await openAuthenticatedDashboard(page);

  try {
    await page.getByLabel("Input channels").selectOption("channels-3-4");
    await expect(page.getByLabel("Input channels")).toHaveValue("channels-3-4");

    await setSwitch(page, /Monitor/, true);
    await setSwitch(page, /Radio/, true);
    await setSwitch(page, /Record/, true);
    await expect(page.getByLabel("Input device")).toBeDisabled();
    await expect(page.getByLabel("Input channels")).toBeDisabled();
    await expect(page.getByLabel("Monitoring output")).toBeEnabled();

    await setSwitch(page, /Record/, false);

    await page.getByLabel("Input gain").fill("6");
    await expect(page.locator("#gain-output")).toHaveText("+6.0 dB");
    await page.getByLabel("1,000 hertz gain").fill("-3");
    await expect(page.locator('output[for="eq-band-5"]')).toHaveText("−3.0 dB");
  } finally {
    await setSwitch(page, /Record/, false);
    await setSwitch(page, /Monitor/, false);
    await setSwitch(page, /Radio/, false);
  }
});

test("does not request browser audio before a user gesture", async ({ page }) => {
  const audioRequests = [];
  page.on("request", (request) => {
    if (request.url().includes("/audio/live.wav")) audioRequests.push(request.url());
  });
  await openAuthenticatedDashboard(page);
  expect(audioRequests).toEqual([]);

  const audio = page.getByLabel("Live PhonoFlow audio");
  const responsePromise = page.waitForResponse((response) =>
    response.url().includes("/audio/live.wav"),
  );
  await page.getByRole("button", { name: "Start browser listening" }).click();
  const response = await responsePromise;
  await expect(audio).toBeVisible();
  await expect.poll(() => audioRequests.length).toBeGreaterThan(0);
  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toContain("audio/wav");
  expect(await audio.evaluate((element) => ({
    error: element.error?.message ?? null,
    hasSource: element.networkState !== 3,
  }))).toEqual({
    error: null,
    hasSource: true,
  });

  // Release the media element's long-lived stream before opening a direct
  // response probe. This keeps the test below the production per-IP stream cap.
  await audio.evaluate((element) => {
    element.pause();
    element.removeAttribute("src");
    element.load();
  });
  await expect.poll(
    () => audio.evaluate((element) => element.networkState),
  ).toBe(0);

  const wav = await probeStreamingWAV(page);
  expect(wav).toMatchObject({
    status: 200,
    riff: "RIFF",
    wave: "WAVE",
    formatChunk: "fmt ",
    dataChunk: "data",
    formatCode: 1,
    channelCount: 2,
    sampleRate: 48_000,
    bitsPerSample: 16,
  });
  expect(wav.contentType).toContain("audio/wav");
  expect(wav.byteLength).toBeGreaterThanOrEqual(4_140);
  expect(wav.dataByteCount).toBeGreaterThan(0);
  expect(wav.payloadByteCount).toBeGreaterThanOrEqual(4_096);
  expect(wav.nonZeroPayloadBytes).toBeGreaterThan(0);
  expect(wav).toMatchObject({
    decodedChannels: 2,
  });
  expect(wav.decodedFrames).toBeGreaterThan(0);
  expect(wav.decodedSampleRate).toBeGreaterThan(0);
  // decodeAudioData is allowed to convert to the machine AudioContext rate.
  // Duration must still match the 1,024-frame, 48 kHz source payload.
  expect(wav.decodedDuration).toBeCloseTo(1_024 / 48_000, 4);
  expect(wav.decodedPeak).toBeGreaterThan(0);
});

test("renders named meter and spectrogram SSE events", async ({ page, request }) => {
  await openAuthenticatedDashboard(page);

  if (externalServer) {
    await expect
      .poll(() => page.locator("#left-meter-value").textContent(), { timeout: 10_000 })
      .not.toBe("−60.0 dB");
    await expect(page.locator("#spectrum-summary")).toContainText("Peak", {
      timeout: 10_000,
    });
  } else {
    await expect.poll(async () => {
      const response = await request.get("/__fixture__/stats");
      return (await response.json()).eventClients;
    }).toBeGreaterThanOrEqual(1);

    await request.post("/__fixture__/event", {
      data: {
        type: "meters",
        payload: { sequence: 9, leftDB: -6, rightDB: -12 },
      },
    });
    await expect(page.locator("#left-meter-value")).toHaveText("−6.0 dB");

    await request.post("/__fixture__/event", {
      data: {
        type: "spectrogram",
        payload: {
          sequence: 9,
          timestamp: "2026-07-24T12:00:00.000Z",
          intensities: Array.from({ length: 64 }, (_, index) => index * 4),
        },
      },
    });
    await expect(page.locator("#spectrum-summary")).toContainText("Peak");
  }

  await page.getByRole("button", { name: "Pause" }).click();
  await expect(page.getByRole("button", { name: "Resume" })).toHaveAttribute("aria-pressed", "true");
});

test("keeps one mobile column and two desktop columns without overflow", async ({ page }) => {
  await openAuthenticatedDashboard(page);

  for (const viewport of [
    { width: 320, height: 800, columns: 1, heroColumns: 1 },
    { width: 390, height: 844, columns: 1, heroColumns: 1 },
    { width: 768, height: 900, columns: 2, heroColumns: 1 },
    { width: 1440, height: 900, columns: 2, heroColumns: 2 },
  ]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    const layout = await page.evaluate(() => {
      const grid = document.querySelector(".dashboard-grid");
      const hero = document.querySelector(".hero");
      const spectrumHeading = document.querySelector(".spectrum-panel .section-heading");
      const spectrumFigure = document.querySelector(".spectrum-panel figure");
      const monitorIcon = document.querySelector("#monitor-toggle .action-icon");
      const recordDot = document.querySelector("#recording-toggle .record-dot");
      const clippedActions = [...document.querySelectorAll(".switch-button:not(.minimal)")].filter(
        (button) => {
          const bounds = button.getBoundingClientRect();
          const contentOverflows = button.scrollWidth > button.clientWidth + 1;
          const childOverflows = [...button.children].some((child) => {
            const childBounds = child.getBoundingClientRect();
            return childBounds.left < bounds.left - 1 || childBounds.right > bounds.right + 1;
          });
          return contentOverflows || childOverflows;
        },
      ).length;
      return {
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        columns: getComputedStyle(grid).gridTemplateColumns.split(" ").filter(Boolean).length,
        heroColumns: getComputedStyle(hero).gridTemplateColumns.split(" ").filter(Boolean).length,
        clippedActions,
        spectrumInset: Math.abs(
          spectrumFigure.getBoundingClientRect().left -
            spectrumHeading.getBoundingClientRect().left,
        ),
        recordIconAlignment: (() => {
          const monitorBounds = monitorIcon.getBoundingClientRect();
          const recordBounds = recordDot.getBoundingClientRect();
          if (innerWidth >= 1088) {
            const monitorButton = monitorIcon.closest(".switch-button").getBoundingClientRect();
            const recordButton = recordDot.closest(".switch-button").getBoundingClientRect();
            return Math.abs(
              (recordBounds.left - recordButton.left)
                - (monitorBounds.left - monitorButton.left),
            );
          }
          return 0;
        })(),
      };
    });
    expect(layout.overflow).toBeLessThanOrEqual(1);
    expect(layout.columns).toBe(viewport.columns);
    expect(layout.heroColumns).toBe(viewport.heroColumns);
    expect(layout.clippedActions).toBe(0);
    expect(layout.spectrumInset).toBeLessThanOrEqual(1);
    expect(layout.recordIconAlignment).toBeLessThanOrEqual(1);
    await expect(page.getByLabel("Input device")).toBeVisible();
    await expect(page.getByLabel("Live PhonoFlow audio")).toBeAttached();
  }
});

test("keeps the light high-contrast palette legible", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light", contrast: "more" });
  await openAuthenticatedDashboard(page);

  const palette = await page.evaluate(() => {
    const body = getComputedStyle(document.body);
    const muted = getComputedStyle(document.querySelector("label"));
    const quiet = getComputedStyle(document.querySelector(".inline-note"));
    const panel = getComputedStyle(document.querySelector(".glass-panel"));
    return {
      text: body.color,
      muted: muted.color,
      quiet: quiet.color,
      stroke: panel.borderColor,
      panelBackground: panel.backgroundColor,
    };
  });
  expect(palette).toMatchObject({
    text: "rgb(7, 19, 28)",
    muted: "rgb(32, 56, 70)",
    quiet: "rgb(48, 73, 86)",
    stroke: "rgba(3, 31, 47, 0.5)",
  });
  expect(palette.panelBackground).not.toBe("rgba(0, 0, 0, 0)");

  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(
    results.violations.filter(({ impact }) =>
      ["critical", "serious"].includes(impact ?? ""),
    ),
  ).toEqual([]);
});

test("removes nonessential motion when requested", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openAuthenticatedDashboard(page);
  const duration = await page.locator(".primary-button").first().evaluate(
    (element) => getComputedStyle(element).transitionDuration,
  );
  expect(Number.parseFloat(duration)).toBeLessThanOrEqual(0.001);
});

test("never loads a third-party runtime resource", async ({ page }) => {
  const foreignRequests = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (["blob:", "data:"].includes(url.protocol)) return;
    if (!["127.0.0.1", "localhost"].includes(url.hostname)) foreignRequests.push(request.url());
  });
  await openAuthenticatedDashboard(page);
  expect(foreignRequests).toEqual([]);
});

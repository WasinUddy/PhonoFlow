import { expect, test as setup } from "@playwright/test";
import {
  access,
  mkdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";

const pairingCode = process.env.PHONOFLOW_PAIRING_CODE ?? "123456";
const sharedStateFileName = "session.json";

async function pathExists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function waitForPath(filePath, timeoutMilliseconds = 30_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (await pathExists(filePath)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    "Another acceptance worker claimed the one-time pairing code but did not "
      + `publish ${filePath} within ${timeoutMilliseconds}ms.`,
  );
}

setup("pair once and save the shared authenticated browser session", async ({
  browser,
}, testInfo) => {
  setup.setTimeout(60_000);

  const stateDirectory = process.env.PHONOFLOW_PLAYWRIGHT_AUTH_DIR
    ?? path.join(process.cwd(), "playwright", ".auth");
  const storageStatePath = path.join(stateDirectory, sharedStateFileName);
  const baseURL = String(
    testInfo.project.use.baseURL
      ?? process.env.PHONOFLOW_WEBUI_URL
      ?? "http://127.0.0.1:4173",
  );
  const pairingAttemptPath = path.join(
    stateDirectory,
    "pairing-attempted",
  );
  await mkdir(stateDirectory, { recursive: true });

  async function verifySavedSession() {
    const savedContext = await browser.newContext({
      baseURL,
      storageState: storageStatePath,
    });
    try {
      const savedPage = await savedContext.newPage();
      const response = await savedPage.goto("/");
      if (response?.ok()) {
        try {
          await expect(
            savedPage.getByRole("heading", { name: "Your sound, in flow." }),
          ).toBeVisible({ timeout: 10_000 });
          await expect(savedPage.locator("#connection-label")).toHaveText(
            "Connected",
            { timeout: 10_000 },
          );
        } catch {
          // The response loaded but did not restore an authenticated dashboard.
        }
      }
      if (
        await savedPage.getByRole("heading", { name: "Your sound, in flow." }).isVisible()
        && await savedPage.locator("#connection-label").textContent() === "Connected"
      ) {
        return true;
      }
    } finally {
      await savedContext.close();
    }
    return false;
  }

  if (await pathExists(storageStatePath)) {
    if (await verifySavedSession()) return;
    throw new Error(
      "The saved PhonoFlow browser session is no longer valid. "
        + "Start a fresh acceptance run with an empty PHONOFLOW_PLAYWRIGHT_AUTH_DIR.",
    );
  }

  try {
    await writeFile(pairingAttemptPath, new Date().toISOString(), {
      encoding: "utf8",
      flag: "wx",
    });
  } catch (error) {
    if (error?.code === "EEXIST") {
      await waitForPath(storageStatePath);
      if (await verifySavedSession()) return;
      throw new Error(
        "Another acceptance worker published an invalid shared browser session.",
      );
    }
    throw error;
  }

  const context = await browser.newContext({ baseURL });
  const temporaryStatePath = path.join(
    stateDirectory,
    `session-${process.pid}-${testInfo.workerIndex}.tmp`,
  );
  try {
    const page = await context.newPage();
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Pair with this Mac" })).toBeVisible();
    await page.getByLabel("Pairing code").fill(pairingCode);

    const pairingResponsePromise = page.waitForResponse((response) => {
      const url = new URL(response.url());
      return url.pathname === "/api/v1/auth/pair"
        && response.request().method() === "POST";
    });
    await page.getByRole("button", { name: "Pair securely" }).click();
    const pairingResponse = await pairingResponsePromise;
    expect(pairingResponse.status()).toBe(200);

    // Persist the HttpOnly cookie immediately after the successful one-time
    // exchange. The atomic rename lets Chromium and WebKit setup workers share
    // one session without ever observing a partial storage-state document.
    await context.storageState({ path: temporaryStatePath });
    await rename(temporaryStatePath, storageStatePath);

    await expect(page.getByRole("heading", { name: "Your sound, in flow." })).toBeVisible();
    await expect(page.locator("#connection-label")).toHaveText("Connected");
  } finally {
    await rm(temporaryStatePath, { force: true });
    await context.close();
  }
});

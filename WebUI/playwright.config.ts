import path from "node:path";
import { defineConfig, devices } from "@playwright/test";

const externalServer = process.env.PHONOFLOW_E2E_EXTERNAL_SERVER === "1";
const baseURL = process.env.PHONOFLOW_WEBUI_URL ?? "http://127.0.0.1:4173";
const authDirectory = path.resolve(
  process.env.PHONOFLOW_PLAYWRIGHT_AUTH_DIR
    ?? path.join(
      "test-results",
      `playwright-auth-${process.pid}-${Date.now()}`,
    ),
);
// Setup projects and their dependent browser projects must agree on one state
// file. Export the generated default before Playwright starts worker processes,
// while keeping explicitly configured CI/native directories unchanged.
process.env.PHONOFLOW_PLAYWRIGHT_AUTH_DIR = authDirectory;
const authStatePath = path.join(authDirectory, "session.json");

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  failOnFlakyTests: Boolean(process.env.CI),
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: process.env.CI
    ? [
        ["line"],
        ["html", { open: "never", outputFolder: "playwright-report" }],
        ["junit", { outputFile: "test-results/results.xml" }]
      ]
    : "line",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  },
  projects: [
    {
      name: "chromium-setup",
      testMatch: /auth\.setup\.ts/,
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 900 }
      }
    },
    {
      name: "chromium",
      testIgnore: /auth\.setup\.ts/,
      dependencies: ["chromium-setup"],
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 900 },
        storageState: authStatePath
      }
    },
    {
      name: "webkit-setup",
      testMatch: /auth\.setup\.ts/,
      retries: 0,
      use: {
        ...devices["Desktop Safari"],
        viewport: { width: 1440, height: 900 }
      }
    },
    {
      name: "webkit",
      testIgnore: /auth\.setup\.ts/,
      dependencies: ["webkit-setup"],
      use: {
        ...devices["Desktop Safari"],
        viewport: { width: 1440, height: 900 },
        storageState: authStatePath
      }
    }
  ],
  ...(!externalServer
    ? {
        webServer: {
          command: "node tests/fixture-server.mjs",
          url: baseURL,
          reuseExistingServer: !process.env.CI,
          timeout: 30_000,
          gracefulShutdown: {
            signal: "SIGTERM",
            timeout: 5_000
          }
        }
      }
    : {})
});

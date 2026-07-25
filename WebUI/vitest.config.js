import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/unit/**/*.test.js"],
    environment: "node",
    coverage: {
      provider: "v8",
      include: ["src/**/*.js"],
      reporter: ["text", "json-summary", "lcovonly", "html"],
      thresholds: {
        lines: 90,
        functions: 90,
        statements: 80,
        branches: 65
      }
    }
  }
});

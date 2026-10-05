import { defineConfig } from "@playwright/test";

// Las pruebas corren contra el build estático (npm run build) servido por el mock, igual que lo serviría nginx.
const PUERTO = Number(process.env.TEST_PORT ?? 5610);

// BASE_URL=http://127.0.0.1:19511 npx playwright test   → contra un contenedor ya levantado (nginx real); no arranca el mock.
const BASE_URL = process.env.BASE_URL;

export default defineConfig({
  testDir: "tests",
  testMatch: /.*\.spec\.ts/,
  timeout: 45_000,
  expect: { timeout: 8_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [["list"]],
  use: {
    baseURL: BASE_URL ?? `http://127.0.0.1:${PUERTO}`,
    channel: "chrome",
    locale: "es-PE",
    timezoneId: "America/Lima",
    trace: "retain-on-failure",
  },
  webServer: BASE_URL
    ? undefined
    : {
        command: "node mock/servidor.mjs",
        env: { PORT: String(PUERTO), SERVIR_DIST: "1" },
        url: `http://127.0.0.1:${PUERTO}/api/salud`,
        reuseExistingServer: true,
        timeout: 20_000,
      },
});

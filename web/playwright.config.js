// playwright.config.js — e2e-смоук мастера против мок-роутера (см. tests/e2e).
//   npm run test:e2e
import { defineConfig } from '@playwright/test';

// E2E_PORT — см. mock-router.mjs (занятый Windows'ом 4317 в WSL mirrored-режиме).
const PORT = Number(process.env.E2E_PORT ?? 4317);

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30_000,
  // Мок-роутер ОДИН на все spec-файлы и держит состояние в памяти — параллельные
  // worker'ы топтали бы его /__reset'ом друг друга (wizard видел панель вместо мастера).
  workers: 1,
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    // chromium в WSL/CI без user-namespaces требует --no-sandbox; тест герметичный.
    launchOptions: { args: ['--no-sandbox'] },
  },
  webServer: {
    command: 'node tests/e2e/mock-router.mjs',
    port: PORT,
    reuseExistingServer: true,
  },
});

import { defineConfig, devices } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '../..');
const PORT = process.env.PORT || '8123';
const baseURL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: './tests',
  // The runtime boot (download ~68MB .data + heap build) is heavy and each Run
  // spawns a worker, so keep it serial and give generous timeouts.
  fullyParallel: false,
  workers: 1,
  timeout: 240_000,
  expect: { timeout: 60_000 },
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    headless: true,
    // COOP/COEP from serve.rkt makes the page cross-origin isolated; the flag
    // is belt-and-suspenders for Chromium builds that gate SAB behind it.
    launchOptions: { args: ['--enable-features=SharedArrayBuffer'] },
    trace: 'on-first-retry',
  },
  // Serve apps/ide/dist/ with the COOP/COEP headers SharedArrayBuffer needs.
  webServer: {
    command: `racket ${resolve(repoRoot, 'build/main.rkt')} serve apps/ide/dist ${PORT}`,
    cwd: repoRoot,
    url: `${baseURL}/`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});

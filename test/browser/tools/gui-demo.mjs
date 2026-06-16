#!/usr/bin/env node
// Drive the racket/gui wasm demo (apps/gui-demo) in headless Chromium:
// boot the runtime, confirm the frame paints (non-blank canvas), click on the
// canvas, and confirm the click round-trips through the GUI event ring into the
// program (the program printf's "click #N"). Saves before/after screenshots.
//
//   node tools/gui-demo.mjs [--headed] [--shot-prefix /tmp/gui]
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = 'apps/gui-demo/dist';

const o = { shotPrefix: '/tmp/gui' };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--headed') o.headed = true;
  else if (a === '--shot-prefix') o.shotPrefix = process.argv[++i];
}

function freePort() {
  return new Promise((res, rej) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => res(port)); });
  });
}
async function waitForHttp(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { const r = await fetch(url, { method: 'HEAD' }); if (r.ok || r.status === 404) return; } catch {}
    if (Date.now() > deadline) throw new Error(`server did not come up at ${url}`);
    await new Promise((r) => setTimeout(r, 200));
  }
}

async function main() {
  const port = await freePort();
  process.stderr.write(`serving ${DIST} on :${port}…\n`);
  const proc = spawn('racket', [resolve(repoRoot, 'build/main.rkt'), 'serve', DIST, String(port)],
                     { cwd: repoRoot, stdio: ['ignore', 'ignore', 'ignore'] });
  const baseURL = `http://127.0.0.1:${port}`;
  await waitForHttp(`${baseURL}/`, 30_000);

  const browser = await chromium.launch({ headless: !o.headed, args: ['--enable-features=SharedArrayBuffer'] });
  try {
    const page = await browser.newPage({ baseURL });
    page.on('console', (m) => process.stderr.write(`[page] ${m.text()}\n`));
    page.on('pageerror', (e) => process.stderr.write(`[pageerror] ${e.message}\n`));
    await page.goto('/', { waitUntil: 'load' });

    process.stderr.write('booting runtime (downloads ~70MB)…\n');
    await page.click('#run');

    // Wait for the program's ready marker in the log.
    await page.locator('#log').filter({ hasText: 'GUI-DEMO-READY' }).waitFor({ timeout: 180_000 });
    process.stderr.write('GUI-DEMO-READY seen\n');

    // The frame should have painted: canvas non-blank.
    const painted = await page.$eval('#frame', (cv) => {
      const ctx = cv.getContext('2d');
      const { data } = ctx.getImageData(0, 0, cv.width, cv.height);
      let nonWhite = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i] !== 255 || data[i + 1] !== 255 || data[i + 2] !== 255) nonWhite++;
      }
      return { w: cv.width, h: cv.height, nonWhite };
    });
    process.stderr.write(`canvas ${painted.w}x${painted.h}, non-white px: ${painted.nonWhite}\n`);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-1-painted.png` });

    // Click on the canvas (inside the drawn rectangle area). The demo's
    // canvas on-event printf's "click #N", proving the event round-tripped
    // through the GUI ring -> pump -> frame -> panel -> canvas.
    const box = await page.locator('#frame').boundingBox();
    await page.mouse.click(box.x + 60, box.y + 50);

    let clicked = false;
    try {
      await page.locator('#log').filter({ hasText: 'click #1' }).waitFor({ timeout: 15_000 });
      clicked = true;
    } catch {}
    // Let the click's (refresh) repaint+blit land before the final screenshot.
    await page.waitForTimeout(1500);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-2-clicked.png` });

    const logText = await page.$eval('#log', (e) => e.textContent);
    process.stdout.write('--- #log ---\n' + logText + '\n--- end ---\n');
    process.stdout.write(`RESULT painted=${painted.nonWhite > 0} clicked=${clicked}\n`);
    if (!(painted.nonWhite > 0 && clicked)) process.exitCode = 1;
  } finally {
    await browser.close();
    try { proc.kill('SIGTERM'); } catch {}
  }
}
main().catch((e) => { process.stderr.write(`error: ${e?.stack || e}\n`); process.exit(1); });

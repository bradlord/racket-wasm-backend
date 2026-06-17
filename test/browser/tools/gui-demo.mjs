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

    // The first blit lands just after GUI-DEMO-READY (show queues the repaint,
    // which runs once the program parks in yield); settle before reading pixels.
    await page.waitForTimeout(600);
    // The frame paints its drawn controls onto a light-gray (236) surface, so
    // count *ink* pixels -- ones that differ from the background by more than a
    // little -- to confirm the controls (text, button border, check) rendered.
    const painted = await page.$eval('#frame', (cv) => {
      const ctx = cv.getContext('2d');
      const { data } = ctx.getImageData(0, 0, cv.width, cv.height);
      let ink = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (Math.abs(data[i] - 236) > 40 || Math.abs(data[i + 1] - 236) > 40 ||
            Math.abs(data[i + 2] - 236) > 40) ink++;
      }
      return { w: cv.width, h: cv.height, ink };
    });
    process.stderr.write(`canvas ${painted.w}x${painted.h}, control ink px: ${painted.ink}\n`);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-1-painted.png` });

    // The demo stacks (border 12, spacing 8) status / button / choice /
    // radio-box at the top, with deterministic positions (above the stretchy
    // gauge/slider/list-box). Click each and wait for the callback's printf.
    // Each click round-trips page -> GUI ring -> pump -> frame -> panel ->
    // control -> callback. Coordinates are canvas px (offsetX/offsetY), 1:1.
    const box = await page.locator('#frame').boundingBox();
    const clickAndWait = async (dx, dy, text) => {
      await page.mouse.click(box.x + dx, box.y + dy);
      try {
        await page.locator('#log').filter({ hasText: text }).waitFor({ timeout: 15_000 });
        return true;
      } catch { return false; }
    };

    // Menus: click the "File" title (in the 24px menu strip), then its first
    // item "New" in the popup (row 0 at ~y36). Selecting closes the popup.
    await page.mouse.click(box.x + 20, box.y + 12);
    await page.waitForTimeout(400);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-3-menu-open.png` });
    const menu = await clickAndWait(40, 36, 'menu: New');

    // The menu bar shifts the control panel down by the 24px strip, so the
    // earlier offsets gain +24: button ~y80, choice ~y118, radio "Two" ~y194.
    const button = await clickAndWait(30, 80, 'button clicked #1');
    const choice = await clickAndWait(30, 118, 'choice -> 1');
    const radio  = await clickAndWait(30, 194, 'radio -> 1');

    // Let the callbacks' repaint+blit land before the final screenshot.
    await page.waitForTimeout(1500);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-2-clicked.png` });

    const logText = await page.$eval('#log', (e) => e.textContent);
    process.stdout.write('--- #log ---\n' + logText + '\n--- end ---\n');
    process.stdout.write(`RESULT painted=${painted.ink > 0} menu=${menu} button=${button} choice=${choice} radio=${radio}\n`);
    if (!(painted.ink > 0 && menu && button && choice && radio)) process.exitCode = 1;
  } finally {
    await browser.close();
    try { proc.kill('SIGTERM'); } catch {}
  }
}
main().catch((e) => { process.stderr.write(`error: ${e?.stack || e}\n`); process.exit(1); });

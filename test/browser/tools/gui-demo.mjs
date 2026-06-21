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

    // Regression: a switchable-button% (transparent canvas) must render on the
    // initial paint -- WITHOUT any click. It sits just below the status message
    // (~x12-48, y~62-96 in canvas px); count ink there. The bug was that a
    // transparent canvas records its drawing rather than filling a bitmap, so the
    // backing flush handed an empty bitmap and the button stayed blank until a
    // click forced a redraw.
    const swInk = await page.$eval('#frame', (cv) => {
      const ctx = cv.getContext('2d');
      const { data, width } = ctx.getImageData(0, 0, cv.width, cv.height);
      let ink = 0;
      for (let y = 62; y < 96; y++)
        for (let x = 12; x < 48; x++) {
          const i = (y * width + x) * 4;
          if (Math.abs(data[i] - 236) > 40 || Math.abs(data[i + 1] - 236) > 40 ||
              Math.abs(data[i + 2] - 236) > 40) ink++;
        }
      return ink;
    });
    process.stderr.write(`switchable-button ink (no click): ${swInk}\n`);
    const switchable = swInk > 0;

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

    // A switchable-button% (transparent canvas, like a DrRacket toolbar button)
    // sits in its own row below the status message, shifting the tested controls
    // down ~37px from their menu-bar-adjusted offsets.
    const button = await clickAndWait(30, 117, 'button clicked #1');
    const choice = await clickAndWait(30, 155, 'choice -> 1');
    const radio  = await clickAndWait(30, 231, 'radio -> 1');

    // Modal dialog: click "Open dialog…" (~y258) to open a 220x110 modal
    // dialog%. It blits its own (smaller) surface, so the single canvas resizes
    // -- proving the topmost window grabbed the canvas. The dialog's lone Close
    // button is stretchy (fills the dialog), so a click at the dialog's centre
    // hits it; selecting it hides the dialog and the parent frame reclaims the
    // canvas (back to 360x580). This exercises the modal nested-yield path.
    await page.mouse.click(box.x + 40, box.y + 295);
    let dialogOpened = false;
    try {
      await page.locator('#log').filter({ hasText: 'dialog: opening' }).waitFor({ timeout: 15_000 });
      await page.waitForTimeout(500);
      const ds = await page.$eval('#frame', (cv) => ({ w: cv.width, h: cv.height }));
      process.stderr.write(`dialog canvas: ${ds.w}x${ds.h}\n`);
      dialogOpened = ds.w === 220 && ds.h === 110;
    } catch {}
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-4-dialog.png` });

    // Click the dialog's centre to hit the stretchy Close button, then confirm
    // the modal show returned (parent prints "dialog: closed") and the canvas
    // grew back to the frame size.
    const dbox = await page.locator('#frame').boundingBox();
    await page.mouse.click(dbox.x + dbox.width / 2, dbox.y + dbox.height / 2);
    let dialogClosed = false;
    try {
      await page.locator('#log').filter({ hasText: 'dialog: closed' }).waitFor({ timeout: 15_000 });
      await page.waitForTimeout(400);
      const fs = await page.$eval('#frame', (cv) => ({ w: cv.width, h: cv.height }));
      dialogClosed = fs.w === 360 && fs.h === 720;
    } catch {}
    const dialog = dialogOpened && dialogClosed;

    // Code editor (text% in editor-canvas%, at the bottom of the 720-tall frame).
    // Click it to focus, then type "hello" -- each keystroke is forwarded into
    // the GUI ring as EVT_KEY_DOWN, routed to the focused canvas, and inserted by
    // text%.on-char. The demo's logging-text% prints the buffer on each edit.
    const rebox = await page.locator('#frame').boundingBox();
    await page.mouse.click(rebox.x + 180, rebox.y + 650);
    await page.waitForTimeout(200);
    await page.keyboard.type('hello', { delay: 60 });
    let editor = false;
    try {
      await page.locator('#log').filter({ hasText: 'editor: "hello"' }).waitFor({ timeout: 15_000 });
      editor = true;
    } catch {}
    await page.waitForTimeout(600);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-5-editor.png` });

    // Let the callbacks' repaint+blit land before the final screenshot.
    await page.waitForTimeout(1500);
    await page.locator('.stage').screenshot({ path: `${o.shotPrefix}-2-clicked.png` });

    const logText = await page.$eval('#log', (e) => e.textContent);
    process.stdout.write('--- #log ---\n' + logText + '\n--- end ---\n');
    process.stdout.write(`RESULT painted=${painted.ink > 0} menu=${menu} switchable=${switchable} button=${button} choice=${choice} radio=${radio} dialog=${dialog} editor=${editor}\n`);
    if (!(painted.ink > 0 && menu && switchable && button && choice && radio && dialog && editor)) process.exitCode = 1;
  } finally {
    await browser.close();
    try { proc.kill('SIGTERM'); } catch {}
  }
}
main().catch((e) => { process.stderr.write(`error: ${e?.stack || e}\n`); process.exit(1); });

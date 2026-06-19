#!/usr/bin/env node
// Positive boot check for the DrRacket WASM dist: boot it headless, and confirm
// it paints its main window onto #frame (non-blank canvas) -- which proves the
// startup sequence (splash -> tool-lib -> frame) completed WITHOUT the place
// crash. Also captures page console/pageerror and watches #log/#status. A clean
// boot paints ink; a place crash leaves the worker dead and the canvas blank.
//
//   node tools/drracket-boot.mjs [--headed] [--timeout 240] [--shot /tmp/drr.png]
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = 'apps/drracket/dist';

const o = { timeout: 240, shot: '/tmp/drr-boot.png' };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--headed') o.headed = true;
  else if (a === '--timeout') o.timeout = Number(process.argv[++i]);
  else if (a === '--shot') o.shot = process.argv[++i];
}

function freePort() {
  return new Promise((res, rej) => {
    const srv = net.createServer(); srv.unref(); srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => res(port)); });
  });
}
async function waitForHttp(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { const r = await fetch(url, { method: 'HEAD' }); if (r.ok || r.status === 404) return; } catch {}
    if (Date.now() > deadline) throw new Error(`not up: ${url}`);
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
  let painted = false, crashedMsg = null;
  try {
    const page = await browser.newPage({ baseURL });
    page.on('console', (m) => {
      const t = m.text();
      if (m.type() === 'error' || /signature mismatch|RuntimeError|abort|undefined/i.test(t))
        process.stderr.write(`[console.${m.type()}] ${t}\n`);
    });
    page.on('pageerror', (e) => { crashedMsg = e.message; process.stderr.write(`[pageerror] ${e.message}\n`); });

    await page.goto('/', { waitUntil: 'load' });
    process.stderr.write('clicking Run…\n');
    await page.click('#run');

    const deadline = Date.now() + o.timeout * 1000;
    let lastLog = '', lastStatus = '', lastDim = '';
    while (Date.now() < deadline) {
      await page.waitForTimeout(2000);
      const log = await page.$eval('#log', (e) => e.textContent).catch(() => '');
      const status = await page.$eval('#status', (e) => e.textContent).catch(() => '');
      if (log !== lastLog) { process.stderr.write(`[#log] ${log.slice(lastLog.length).replace(/\s+/g, ' ').trim()}\n`); lastLog = log; }
      if (status !== lastStatus) { process.stderr.write(`[#status] ${status}\n`); lastStatus = status; }
      const ink = await page.$eval('#frame', (cv) => {
        const ctx = cv.getContext('2d');
        const { data } = ctx.getImageData(0, 0, cv.width, cv.height);
        let n = 0;
        const r0 = data[0], g0 = data[1], b0 = data[2];
        for (let i = 0; i < data.length; i += 4) {
          if (Math.abs(data[i] - r0) > 24 || Math.abs(data[i + 1] - g0) > 24 || Math.abs(data[i + 2] - b0) > 24) n++;
        }
        return { w: cv.width, h: cv.height, ink: n };
      }).catch(() => ({ w: 0, h: 0, ink: 0 }));
      const dim = `${ink.w}x${ink.h} ink=${ink.ink}`;
      if (dim !== lastDim) { process.stderr.write(`[#frame] ${dim}\n`); lastDim = dim; }
      if (ink.ink > 200) painted = true;
    }

    await page.locator('.stage').screenshot({ path: o.shot }).catch(() => page.screenshot({ path: o.shot }).catch(() => {}));
    process.stdout.write(`\nRESULT painted=${painted} crash=${crashedMsg ? JSON.stringify(crashedMsg) : 'none'}\n`);
    process.exitCode = painted ? 0 : 1;
  } finally {
    await browser.close();
    try { proc.kill('SIGTERM'); } catch {}
  }
}
main().catch((e) => { process.stderr.write(`error: ${e?.stack || e}\n`); process.exit(1); });

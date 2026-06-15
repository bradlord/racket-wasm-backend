// Diagnostic: boot the IDE, capture ALL browser/worker console + errors, dump
// final #status/#output. Used to debug a boot that never reaches "Running".
import { chromium } from 'playwright';
import { startServer } from '../lib/server.mjs';

const server = await startServer();
const browser = await chromium.launch();
const ctx = await browser.newContext({ baseURL: server.baseURL });
const page = await ctx.newPage();

const log = (tag, s) => console.error(`[${tag}] ${s}`);
page.on('console', (m) => log('page:' + m.type(), m.text()));
page.on('pageerror', (e) => log('pageerror', e.message));
page.on('worker', (w) => {
  log('worker', 'spawned ' + w.url());
  w.on('console', (m) => log('worker:' + m.type(), m.text()));
});
ctx.on('weberror', (e) => log('weberror', e.error().message));

await page.goto('/', { waitUntil: 'domcontentloaded' });
await page.fill('#editor', '#lang racket/base\n');
await page.click('#run');

// Wait up to 60s for Running, else report whatever we have.
let reached = false;
try {
  await page.waitForFunction(
    () => document.getElementById('status').textContent === 'Running',
    null,
    { timeout: 60000 },
  );
  reached = true;
} catch (_) {}

const status = await page.$eval('#status', (e) => e.textContent);
const out = await page.$eval('#output', (e) => e.textContent);
log('FINAL', `reachedRunning=${reached} status=${JSON.stringify(status)}`);
log('OUTPUT', JSON.stringify(out.slice(0, 2000)));

await browser.close();
await server.stop();
process.exit(reached ? 0 : 2);

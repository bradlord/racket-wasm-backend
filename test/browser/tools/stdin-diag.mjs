// stdin diagnostic: boot the REPL, then observe whether the runtime signals
// "waiting for input" (io-state -> the inputRow .waiting class) and whether a
// submitted line produces any output. Dumps console + final state.
import { chromium } from 'playwright';
import { startServer } from '../lib/server.mjs';

const server = await startServer();
const browser = await chromium.launch();
const ctx = await browser.newContext({ baseURL: server.baseURL });
const page = await ctx.newPage();
const log = (t, s) => console.error(`[${t}] ${s}`);
page.on('console', (m) => log('page:' + m.type(), m.text()));
page.on('pageerror', (e) => log('pageerror', e.message));
page.on('worker', (w) => w.on('console', (m) => log('worker:' + m.type(), m.text())));

await page.goto('/', { waitUntil: 'domcontentloaded' });
await page.fill('#editor', '#lang racket/base\n');
await page.click('#run');
await page.waitForFunction(
  () => document.getElementById('status').textContent === 'Running',
  null, { timeout: 60000 },
);
log('status', 'Running reached');

const snap = async (label) => {
  const s = await page.evaluate(() => ({
    out: document.getElementById('output').textContent.slice(-400),
    waiting: document.getElementById('inputRow')?.className || '(no inputRow)',
    evalDisabled: document.getElementById('evaluate')?.disabled,
    inputDisabled: document.getElementById('input')?.disabled,
  }));
  log(label, JSON.stringify(s));
};

// Give the boot/bootstrap a moment, then snapshot.
await page.waitForTimeout(4000);
await snap('after-boot');

// Submit a line directly.
await page.fill('#input', '(+ 4 5)');
await page.click('#evaluate');
log('submit', 'clicked evaluate with (+ 4 5)');
await page.waitForTimeout(6000);
await snap('after-submit');

await browser.close();
await server.stop();

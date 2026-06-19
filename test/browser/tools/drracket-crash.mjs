#!/usr/bin/env node
// Boot the DrRacket WASM dist headless and capture the startup crash with as
// much stack as the engine will give us. The runtime runs inside nested
// pthread Web Workers (racket-web.js, spawned by shell-worker.js); their
// console + uncaught traps do NOT bubble to page.on('console'). So we drive a
// raw CDP session with Target.setAutoAttach(flatten) and, on every attached
// target, enable Runtime/Log and forward console API calls + exceptionThrown
// (RuntimeError "function signature mismatch" lands here, with a wasm stack).
//
//   node tools/drracket-crash.mjs [--headed] [--timeout 240]
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = 'apps/drracket/dist';

const o = { timeout: 240 };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--headed') o.headed = true;
  else if (a === '--timeout') o.timeout = Number(process.argv[++i]);
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

const events = [];
let crashed = false;

function fmtRemote(arg) {
  if (arg == null) return String(arg);
  if (arg.value !== undefined) return String(arg.value);
  if (arg.description) return arg.description;
  if (arg.unserializableValue) return arg.unserializableValue;
  return arg.type;
}

async function wireTarget(session, label) {
  try {
    await session.send('Runtime.enable');
    await session.send('Log.enable').catch(() => {});
  } catch {}
  session.on('Runtime.consoleAPICalled', (e) => {
    const text = (e.args || []).map(fmtRemote).join(' ');
    process.stderr.write(`[${label}:${e.type}] ${text}\n`);
    if (/signature mismatch|RuntimeError|abort\(|Aborted/i.test(text)) crashed = true;
  });
  session.on('Runtime.exceptionThrown', (e) => {
    const d = e.exceptionDetails || {};
    const ex = d.exception || {};
    const stack = (d.stackTrace?.callFrames || [])
      .map((f) => `    at ${f.functionName || '<anon>'} (${f.url}:${f.lineNumber}:${f.columnNumber})`)
      .join('\n');
    const msg = `[${label}:EXCEPTION] ${d.text || ''} ${ex.description || ex.value || ''}\n${stack}`;
    process.stderr.write(msg + '\n');
    events.push(msg);
    crashed = true;
  });
  session.on('Log.entryAdded', (e) => {
    const t = e.entry?.text || '';
    process.stderr.write(`[${label}:log:${e.entry?.level}] ${t}\n`);
    if (/signature mismatch|RuntimeError|abort/i.test(t)) { crashed = true; events.push(t); }
  });
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
    const ctx = page.context();

    // Capture exceptions/console from the page and EVERY worker -- including the
    // nested pthread workers (racket-web.js) where the trap fires. Playwright
    // surfaces each worker as a Worker object; attach a per-worker CDP session.
    const rootSession = await ctx.newCDPSession(page).catch(() => null);
    if (rootSession) await wireTarget(rootSession, 'page');

    const wireWorker = async (w) => {
      const label = 'wkr:' + (w.url() || '').split('/').pop();
      process.stderr.write(`[worker] ${label}\n`);
      try {
        const s = await ctx.newCDPSession(w);
        await wireTarget(s, label);
      } catch (e) {
        process.stderr.write(`[worker] could not attach CDP to ${label}: ${e.message}\n`);
      }
    };
    page.on('worker', wireWorker);
    for (const w of page.workers()) await wireWorker(w);

    await page.goto('/', { waitUntil: 'load' });
    process.stderr.write('booting runtime…\n');
    await page.click('#run');

    const deadline = Date.now() + o.timeout * 1000;
    let lastLog = '';
    while (Date.now() < deadline && !crashed) {
      await page.waitForTimeout(1000);
      const cur = await page.$eval('#log', (e) => e.textContent).catch(() => '');
      if (cur !== lastLog) { lastLog = cur; }
      if (/signature mismatch|RuntimeError|abort\(|Aborted/i.test(cur)) { crashed = true; events.push(`[#log]\n${cur}`); }
    }

    const logText = await page.$eval('#log', (e) => e.textContent).catch(() => '(no #log)');
    process.stdout.write('\n--- #log ---\n' + logText + '\n--- end #log ---\n');
    if (events.length) process.stdout.write('\n--- captured ---\n' + events.join('\n\n') + '\n--- end ---\n');
    process.stdout.write(`\nRESULT crashed=${crashed}\n`);
    process.exitCode = crashed ? 2 : 0;
  } finally {
    await browser.close();
    try { proc.kill('SIGTERM'); } catch {}
  }
}
main().catch((e) => { process.stderr.write(`error: ${e?.stack || e}\n`); process.exit(1); });

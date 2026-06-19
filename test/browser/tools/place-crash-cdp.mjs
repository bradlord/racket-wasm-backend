#!/usr/bin/env node
// Reproduce the forked-thread (place) foreign-call trap in the browser build.
// Boots the IDE dist (dist/), runs a Definitions module that spawns a trivial
// place via dynamic-place, and captures any trap from ANY target -- including
// the nested pthread workers where the trap fires -- via raw CDP auto-attach.
// (dist/shell-worker.js must have its printErr forward to console for the
// emscripten "worker sent an error!" text to surface.)
//
//   node tools/place-crash-cdp.mjs [--timeout 180]
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = 'dist';
const CHROME = chromium.executablePath();

const o = { timeout: 180 };
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--timeout') o.timeout = Number(process.argv[++i]);
}

const EDITOR_SRC = `#lang racket/base
(require racket/place racket/file)
(define src "#lang racket/base\\n(provide go)\\n(define (go ch) (place-channel-put ch 42))\\n")
(call-with-output-file "/tmp/pl.rkt" (lambda (o) (write-string src o)) #:exists 'replace)
(printf "MAIN-BEFORE-PLACE\\n") (flush-output)
(define p (dynamic-place (string->path "/tmp/pl.rkt") 'go))
(printf "MAIN-PLACE-SAID ~a\\n" (place-channel-get p)) (flush-output)
(printf "MAIN-DONE\\n") (flush-output)
`;

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
async function getJSON(url) { return (await fetch(url)).json(); }

class CDP {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.handlers = []; }
  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    const c = new CDP(ws);
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && c.pending.has(msg.id)) {
        const { res, rej } = c.pending.get(msg.id); c.pending.delete(msg.id);
        msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
      } else if (msg.method) { for (const h of c.handlers) h(msg.method, msg.params, msg.sessionId); }
    };
    return c;
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  on(fn) { this.handlers.push(fn); }
}

const events = [];
let crashed = false;
function note(s) { process.stderr.write(s + '\n'); }
function fmtArg(a) { if (!a) return String(a); if (a.value !== undefined) return String(a.value); return a.description || a.unserializableValue || a.type || ''; }
const RX = /signature mismatch|RuntimeError|worker sent an error|abort\(|Aborted|memory access out of bounds/i;

async function main() {
  const port = await freePort();
  note(`serving ${DIST} on :${port}…`);
  const serve = spawn('racket', [resolve(repoRoot, 'build/main.rkt'), 'serve', DIST, String(port)],
                      { cwd: repoRoot, stdio: ['ignore', 'ignore', 'ignore'] });
  const baseURL = `http://127.0.0.1:${port}`;
  await waitForHttp(`${baseURL}/`, 30_000);

  const dbgPort = await freePort();
  const userDir = `/tmp/place-cdp-${process.pid}`;
  const chrome = spawn(CHROME, [
    '--headless=new', `--remote-debugging-port=${dbgPort}`, `--user-data-dir=${userDir}`,
    '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--enable-features=SharedArrayBuffer',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  chrome.stderr.on('data', () => {});

  await waitForHttp(`http://127.0.0.1:${dbgPort}/json/version`, 30_000);
  const version = await getJSON(`http://127.0.0.1:${dbgPort}/json/version`);
  const cdp = await CDP.connect(version.webSocketDebuggerUrl);

  let pageSession = null;
  cdp.on(async (method, params, sessionId) => {
    if (method === 'Target.attachedToTarget') {
      const sid = params.sessionId; const ti = params.targetInfo;
      const label = `${ti.type}:${(ti.url || '').split('/').pop() || ti.type}`;
      note(`[attached] ${label}`);
      try {
        await cdp.send('Runtime.enable', {}, sid);
        await cdp.send('Log.enable', {}, sid).catch(() => {});
        if (ti.type === 'page' && !pageSession) pageSession = sid;
        await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid).catch(() => {});
        await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid).catch(() => {});
      } catch {}
    } else if (method === 'Runtime.exceptionThrown') {
      const d = params.exceptionDetails || {}; const ex = d.exception || {};
      const stack = (d.stackTrace?.callFrames || [])
        .map((f) => `    at ${f.functionName || '<anon>'} (${(f.url || '').split('/').pop()}:${f.lineNumber}:${f.columnNumber})`).join('\n');
      const msg = `[EXCEPTION ${sessionId?.slice(0, 8)}] ${d.text || ''} ${ex.description || ex.value || ''}\n${stack}`;
      note(msg); events.push(msg); crashed = true;
    } else if (method === 'Runtime.consoleAPICalled') {
      const text = (params.args || []).map(fmtArg).join(' ');
      if (params.type === 'error' || RX.test(text)) {
        note(`[console.${params.type} ${sessionId?.slice(0, 8)}] ${text}`);
        if (RX.test(text)) { crashed = true; events.push(text); }
      }
    } else if (method === 'Log.entryAdded') {
      const t = params.entry?.text || '';
      if (RX.test(t)) { note(`[log] ${t}`); crashed = true; events.push(t); }
    }
  });
  await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
  await cdp.send('Target.createTarget', { url: 'about:blank' });
  for (let i = 0; i < 100 && !pageSession; i++) await new Promise((r) => setTimeout(r, 50));
  if (!pageSession) throw new Error('no page session');

  await cdp.send('Page.enable', {}, pageSession).catch(() => {});
  await cdp.send('Page.navigate', { url: baseURL }, pageSession);
  await new Promise((r) => setTimeout(r, 2500));

  note('setting editor + clicking Run…');
  await cdp.send('Runtime.evaluate', {
    expression: `(() => { const ed=document.getElementById('editor'); ed.value=${JSON.stringify(EDITOR_SRC)}; ed.dispatchEvent(new Event('input',{bubbles:true})); document.getElementById('run').click(); return 'ran'; })()`,
    returnByValue: true,
  }, pageSession);

  const readOut = async () => {
    try {
      const r = await cdp.send('Runtime.evaluate', { expression: `document.getElementById('output').textContent`, returnByValue: true }, pageSession);
      return r.result?.value || '';
    } catch { return ''; }
  };
  const readStatus = async () => {
    try {
      const r = await cdp.send('Runtime.evaluate', { expression: `document.getElementById('status').textContent`, returnByValue: true }, pageSession);
      return r.result?.value || '';
    } catch { return ''; }
  };

  const deadline = Date.now() + o.timeout * 1000;
  let last = '';
  while (Date.now() < deadline && !crashed) {
    await new Promise((r) => setTimeout(r, 1000));
    const cur = await readOut();
    if (cur !== last) { if (cur.length > last.length) note(`[#output] ${cur.slice(last.length).replace(/\s+/g, ' ').trim()}`); last = cur; }
    if (/MAIN-PLACE-SAID|MAIN-DONE/.test(cur)) { note('PLACE SUCCEEDED (no crash)'); break; }
    if (RX.test(cur)) { crashed = true; events.push(`[#output]\n${cur}`); }
  }

  const status = await readStatus();
  process.stdout.write(`\n--- status: ${status} ---`);
  process.stdout.write('\n--- #output ---\n' + last + '\n--- end ---\n');
  if (events.length) process.stdout.write('\n--- captured ---\n' + events.join('\n\n') + '\n--- end ---\n');
  const succeeded = /MAIN-PLACE-SAID|MAIN-DONE/.test(last);
  process.stdout.write(`\nRESULT crashed=${crashed} placeSucceeded=${succeeded}\n`);

  try { chrome.kill('SIGKILL'); } catch {}
  try { serve.kill('SIGTERM'); } catch {}
  process.exit(crashed ? 2 : succeeded ? 0 : 3);
}
main().catch((e) => { note(`error: ${e?.stack || e}`); process.exit(1); });

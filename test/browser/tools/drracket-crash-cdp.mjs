#!/usr/bin/env node
// Boot the DrRacket WASM dist in headless Chrome and capture the startup crash
// from ANY target -- including the nested pthread Web Workers (racket-web.js)
// where the trap actually fires. Playwright can't attach a CDP session to a
// Worker in this version, so we speak CDP directly over a WebSocket:
// Target.setAutoAttach{flatten,waitForDebuggerOnStart} at the browser level
// attaches to every page + (nested) worker before its code runs; we enable
// Runtime on each and collect Runtime.exceptionThrown (the RuntimeError
// "function signature mismatch", with a JS/wasm stack) + console.
//
//   node tools/drracket-crash-cdp.mjs [--timeout 180]
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = 'apps/drracket/dist';
const CHROME = chromium.executablePath();

const o = { timeout: 180 };
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--timeout') o.timeout = Number(process.argv[++i]);
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
async function getJSON(url) { return (await fetch(url)).json(); }

// --- tiny CDP client over a single flattened browser websocket -------------
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
      } else if (msg.method) {
        for (const h of c.handlers) h(msg.method, msg.params, msg.sessionId);
      }
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

function fmtArg(a) {
  if (!a) return String(a);
  if (a.value !== undefined) return String(a.value);
  return a.description || a.unserializableValue || a.type || '';
}

async function main() {
  const port = await freePort();
  note(`serving ${DIST} on :${port}…`);
  const serve = spawn('racket', [resolve(repoRoot, 'build/main.rkt'), 'serve', DIST, String(port)],
                      { cwd: repoRoot, stdio: ['ignore', 'ignore', 'ignore'] });
  const baseURL = `http://127.0.0.1:${port}`;
  await waitForHttp(`${baseURL}/`, 30_000);

  const dbgPort = await freePort();
  const userDir = `/tmp/drr-cdp-${process.pid}`;
  const chrome = spawn(CHROME, [
    '--headless=new', `--remote-debugging-port=${dbgPort}`, `--user-data-dir=${userDir}`,
    '--no-first-run', '--no-default-browser-check', '--disable-gpu',
    '--enable-features=SharedArrayBuffer',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  chrome.stderr.on('data', () => {}); // swallow

  await waitForHttp(`http://127.0.0.1:${dbgPort}/json/version`, 30_000);
  const version = await getJSON(`http://127.0.0.1:${dbgPort}/json/version`);
  const cdp = await CDP.connect(version.webSocketDebuggerUrl);

  const sessions = new Set();
  let pageSession = null;
  cdp.on(async (method, params, sessionId) => {
    if (method === 'Target.attachedToTarget') {
      const sid = params.sessionId;
      const ti = params.targetInfo;
      const label = `${ti.type}:${(ti.url || '').split('/').pop() || ti.type}`;
      sessions.add(sid);
      note(`[attached] ${label} (${sid.slice(0, 8)})`);
      try {
        await cdp.send('Runtime.enable', {}, sid);
        await cdp.send('Log.enable', {}, sid).catch(() => {});
        if (ti.type === 'page' && !pageSession) pageSession = sid;
        // Recurse: attach to this target's children too.
        await cdp.send('Target.setAutoAttach',
          { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid).catch(() => {});
        await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid).catch(() => {});
      } catch (e) { note(`[attach err] ${label}: ${e.message}`); }
    } else if (method === 'Runtime.exceptionThrown') {
      const d = params.exceptionDetails || {};
      const ex = d.exception || {};
      const stack = (d.stackTrace?.callFrames || [])
        .map((f) => `    at ${f.functionName || '<anon>'} (${(f.url || '').split('/').pop()}:${f.lineNumber}:${f.columnNumber})`)
        .join('\n');
      const msg = `[EXCEPTION ${sessionId?.slice(0, 8)}] ${d.text || ''} ${ex.description || ex.value || ''}\n${stack}`;
      note(msg); events.push(msg); crashed = true;
    } else if (method === 'Runtime.consoleAPICalled') {
      const text = (params.args || []).map(fmtArg).join(' ');
      if (params.type === 'error' || /signature mismatch|RuntimeError|abort|Aborted/i.test(text)) {
        note(`[console.${params.type} ${sessionId?.slice(0, 8)}] ${text}`);
        if (/signature mismatch|RuntimeError|abort/i.test(text)) { crashed = true; events.push(text); }
      }
    } else if (method === 'Log.entryAdded') {
      const t = params.entry?.text || '';
      if (params.entry?.level === 'error' || /signature mismatch|RuntimeError|abort/i.test(t)) {
        note(`[log ${sessionId?.slice(0, 8)}] ${t}`);
        if (/signature mismatch|RuntimeError|abort/i.test(t)) { crashed = true; events.push(t); }
      }
    }
  });

  // Auto-attach from the browser root to all targets (flatten) BEFORE creating
  // the page, so workers pause at start until we enable Runtime.
  await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });

  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  // Wait for the page session to come up.
  for (let i = 0; i < 100 && !pageSession; i++) await new Promise((r) => setTimeout(r, 50));
  if (!pageSession) throw new Error('no page session attached');

  await cdp.send('Page.enable', {}, pageSession).catch(() => {});
  await cdp.send('Page.navigate', { url: baseURL }, pageSession);
  await new Promise((r) => setTimeout(r, 2500));
  note('booting runtime (click #run)…');
  await cdp.send('Runtime.evaluate',
    { expression: `document.getElementById('run').click()` }, pageSession);

  const readLog = async () => {
    try {
      const r = await cdp.send('Runtime.evaluate',
        { expression: `document.getElementById('log').textContent`, returnByValue: true }, pageSession);
      return r.result?.value || '';
    } catch { return ''; }
  };

  const deadline = Date.now() + o.timeout * 1000;
  let last = '';
  while (Date.now() < deadline && !crashed) {
    await new Promise((r) => setTimeout(r, 1000));
    const cur = await readLog();
    if (cur !== last) { if (cur.length > last.length) note(`[#log] ${cur.slice(last.length).trim()}`); last = cur; }
    if (/signature mismatch|RuntimeError|abort\(|Aborted/i.test(cur)) { crashed = true; events.push(`[#log]\n${cur}`); }
  }

  process.stdout.write('\n--- #log ---\n' + last + '\n--- end ---\n');
  if (events.length) process.stdout.write('\n--- captured ---\n' + events.join('\n\n') + '\n--- end ---\n');
  process.stdout.write(`\nRESULT crashed=${crashed}\n`);

  try { chrome.kill('SIGKILL'); } catch {}
  try { serve.kill('SIGTERM'); } catch {}
  process.exit(crashed ? 2 : 0);
}
main().catch((e) => { note(`error: ${e?.stack || e}`); process.exit(1); });

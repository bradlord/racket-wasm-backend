// Start/stop the COOP/COEP dev server (serve.rkt, via the orchestrator's
// `serve` subcommand) for the ad-hoc CLI. Playwright specs use the webServer in
// playwright.config.mjs instead; this is for tools/eval.mjs.
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');

// An OS-assigned free TCP port.
export function freePort() {
  return new Promise((res, rej) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => res(port));
    });
  });
}

async function waitForHttp(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const r = await fetch(url, { method: 'HEAD' });
      if (r.ok || r.status === 404) return; // server is up and answering
    } catch {
      /* not listening yet */
    }
    if (Date.now() > deadline) throw new Error(`server did not come up at ${url}`);
    await new Promise((r) => setTimeout(r, 200));
  }
}

// Spawn `racket build/main.rkt serve dist <port>` (serves dist/). Resolves to a
// handle with { port, baseURL, stop() }.
export async function startServer({ port, timeoutMs = 30_000 } = {}) {
  port = port || (await freePort());
  const proc = spawn('racket', [resolve(repoRoot, 'build/main.rkt'), 'serve', 'dist', String(port)], {
    cwd: repoRoot,
    // Quiet: serve.rkt doesn't trap SIGTERM, so killing it on stop() would
    // otherwise print a backtrace to our stderr. Startup failures still surface
    // via the waitForHttp timeout below.
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  proc.on('error', (e) => {
    throw new Error(`failed to start serve.rkt (is racket on PATH? is dist/ built?): ${e.message}`);
  });
  const baseURL = `http://127.0.0.1:${port}`;
  await waitForHttp(`${baseURL}/`, timeoutMs);
  return {
    port,
    baseURL,
    stop() {
      try {
        proc.kill('SIGTERM');
      } catch {
        /* already gone */
      }
    },
  };
}

// Page object for the Racket WASM IDE (ide.html), usable from both
// @playwright/test specs and the raw-playwright `tools/eval.mjs` CLI -- it only
// touches the common `page` API.
//
// The IDE is DrRacket-shaped: a Definitions editor (#editor) saved to
// /tmp/main.rkt, a Run button (#run) that spawns a fresh worker process, and an
// Interactions pane (#output, a <pre> with text + inline <canvas> per blit) fed
// by a REPL whose stdin is #input/#evaluate. Status shows in #status.
//
// Determinism: the runtime's output is heavily buffered and the IDE *echoes*
// submitted input into #output, so we don't time-wait -- after each submission
// we push a marker form whose *source* never contains the marker *text* (it is
// assembled at runtime via string-append), wait for that text to appear, then
// strip the exact strings we submitted (echoes + marker). See `submitMarker`.

const RUN_TIMEOUT = 180_000; // browser boot (download ~68MB .data + heap build)

/* ---- low-level transcript helpers ---------------------------------- */

const outLen = (page) => page.$eval('#output', (e) => e.textContent.length);
const outText = (page) => page.$eval('#output', (e) => e.textContent);

async function submit(page, text) {
  // evaluate() ignores empty input and requires the runtime to be ready.
  await page.fill('#input', text);
  await page.click('#evaluate');
}

const removeFirst = (s, sub) => {
  const i = s.indexOf(sub);
  return i < 0 ? s : s.slice(0, i) + s.slice(i + sub.length);
};

// Submit a marker form and wait for its OUTPUT, then return the transcript since
// `cursor` with the marker's own echo + output removed.
//
// The IDE echoes submitted input into #output *synchronously*, but program
// output arrives *asynchronously* (drained on rAF), so the echo and the output
// it precedes can land out of order. We therefore never slice by position --
// the marker text is assembled at runtime (so it never appears in the echoed
// source), and we strip the exact strings we know we submitted.
async function submitMarker(page, cursor, timeout) {
  const n = Math.random().toString(36).slice(2, 12);
  const tok = 'RKTDONE' + n; // appears only as displayln OUTPUT, never in source
  const src = `(displayln (string-append "RKTDONE" "${n}"))`;
  await submit(page, src);
  await page.waitForFunction(
    (t) => document.getElementById('output').textContent.includes(t),
    tok,
    { timeout },
  );
  let txt = (await outText(page)).slice(cursor);
  txt = removeFirst(txt, src.endsWith('\n') ? src : src + '\n'); // marker echo
  txt = removeFirst(txt, tok + '\n'); // marker output
  return removeFirst(txt, tok);
}

// Strip REPL noise from a captured transcript: the boot banner and the `> `
// prompts the REPL prints while waiting for input (one or more can cluster at a
// line start, e.g. "> > 4950"). Leaves program output and printed values.
function clean(s) {
  s = s.replace(/Welcome to Racket[^\n]*\n?/g, '');
  let prev;
  do {
    prev = s;
    s = s.replace(/(^|\n)(?:> )+/g, '$1');
  } while (s !== prev);
  return s.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

/* ---- public API ---------------------------------------------------- */

// Open the IDE and assert cross-origin isolation (else the runtime can't start).
export async function gotoIde(page) {
  await page.goto('/ide.html', { waitUntil: 'domcontentloaded' });
  const isolated = await page.evaluate(
    () => typeof SharedArrayBuffer !== 'undefined' && typeof Atomics !== 'undefined',
  );
  if (!isolated) {
    throw new Error(
      'SharedArrayBuffer unavailable: the page is not cross-origin isolated. ' +
        'Serve dist/ with COOP/COEP (serve.rkt does) and use a Chromium that honors it.',
    );
  }
}

// Wait until a freshly-run worker reaches the live REPL ("Running").
async function waitRunning(page, timeout) {
  await page.waitForFunction(
    () => document.getElementById('status').textContent === 'Running',
    null,
    { timeout },
  );
}

// Boot a REPL on a minimal module, ready for evalRepl(). Returns when quiescent.
export async function bootRepl(page, { editor = '#lang racket/base\n', timeout = RUN_TIMEOUT } = {}) {
  await page.fill('#editor', editor);
  await page.click('#run');
  await waitRunning(page, timeout);
  await submitMarker(page, 0, timeout); // drain the initial (empty) module run
}

// Run `source` (a full #lang module) as the Definitions program; return its
// stdout (the module body's output), like clicking Run on a file.
export async function loadAndRun(page, source, { timeout = RUN_TIMEOUT } = {}) {
  await page.fill('#editor', source);
  await page.click('#run');
  await waitRunning(page, timeout);
  // run() clears #output, so the transcript from 0 is just the module's output.
  return clean(await submitMarker(page, 0, timeout));
}

// Evaluate `code` at the REPL (boot the REPL first); return just its output
// (the echoed submission is stripped).
export async function evalRepl(page, code, { timeout = RUN_TIMEOUT } = {}) {
  const cursor = await outLen(page);
  await submit(page, code);
  let txt = await submitMarker(page, cursor, timeout);
  txt = removeFirst(txt, code.endsWith('\n') ? code : code + '\n'); // strip code echo
  return clean(txt);
}

// Number of inline <canvas> images currently in the Interactions pane (each
// racket/draw blit via web-repl/display-bm appends one).
export const canvasCount = (page) => page.$$eval('#output canvas', (els) => els.length);

// The current Interactions status chip text (e.g. "Running", "Exited 0").
export const status = (page) => page.$eval('#status', (e) => e.textContent);

export { RUN_TIMEOUT };

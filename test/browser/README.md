# Browser tests for the Racket WASM IDE

Headless-Chromium tests and an ad-hoc eval CLI that drive the real `index.html`
browser surface from `apps/ide/dist/`. They exercise the whole browser stack: cross-origin
isolation, the SharedArrayBuffer stdin/stdout rings, the submission REPL,
`racket/draw` + the canvas blit channel, and the `web-repl` helpers.

Playwright is used because headless Chromium honors the COOP/COEP headers
`serve.rkt` sets, so `SharedArrayBuffer` (and thus the `-pthread` runtime) works.

## Prerequisites

- A built `apps/ide/dist/` (`racket build/main.rkt app apps/ide …` from the repo root).
- `racket` on `PATH` (to run `serve.rkt`).
- Node 18+.

## Setup

```sh
cd test/browser
npm install
npm run install-browser     # downloads the Chromium Playwright uses
```

## Run the test suite (CI-style)

```sh
npm test                    # starts the server, runs tests/*.spec.mjs
```

The Playwright config starts `racket build/main.rkt serve` itself (COOP/COEP) and
points the browser at it. Set `PORT` to override the default 8123.

## Ad-hoc: run code and see the output

The `eval` CLI is for quick checks and AI agents — program output goes to
stdout, diagnostics to stderr.

```sh
# a REPL expression
node tools/eval.mjs '(+ 1 2)'

# several forms
node tools/eval.mjs '(require racket/list) (range 5)'

# a whole module (anything starting with #lang runs as a module)
node tools/eval.mjs --file ../../examples/hello/public/main.rkt
echo '#lang racket/base
(displayln (for/sum ([i 100]) i))' | node tools/eval.mjs -

# draw something and screenshot the Interactions pane (a #lang module, so the
# requires take effect before the body — at the REPL, require and use must be
# separate submissions because a submission's forms are all expanded up front)
node tools/eval.mjs --shot /tmp/out.png '#lang racket
(require racket/draw web-repl/display-bm)
(define bm (make-bitmap 60 60))
(define dc (send bm make-dc))
(send dc set-brush "dodgerblue" (quote solid))
(send dc draw-ellipse 2 2 56 56)
(display-bm bm)'

# reuse an already-running server (racket build/main.rkt serve apps/ide/dist 8123)
node tools/eval.mjs --url http://127.0.0.1:8123 '(+ 1 2)'

# watch it happen
node tools/eval.mjs --headed '(+ 1 2)'
```

## Writing tests

Specs use `@playwright/test` and the page object in `lib/ide.mjs`:

```js
import { test, expect } from '@playwright/test';
import { gotoIde, bootRepl, evalRepl, loadAndRun, canvasCount } from '../lib/ide.mjs';

test('my check', async ({ page }) => {
  await gotoIde(page);
  await bootRepl(page);
  expect(await evalRepl(page, '(* 6 7)')).toContain('42');
});
```

Page object (`lib/ide.mjs`):

- `gotoIde(page)` — open the IDE; throws if not cross-origin isolated.
- `bootRepl(page, {editor})` — start a REPL (default minimal module).
- `evalRepl(page, code)` — evaluate at the REPL; returns its output.
- `loadAndRun(page, source)` — run a `#lang` module; returns its stdout.
- `canvasCount(page)` / `status(page)` — inline-image count / status chip text.

Output is captured deterministically (no sleeps): each submission is followed by
a marker form whose text is assembled at runtime, so we wait for the marker
rather than guessing when buffered output has flushed.

## CI

`.github/workflows/browser-tests.yml` installs racket + node + Chromium and runs
the suite. It expects a prebuilt `apps/ide/dist/` (the WASM build needs emsdk +
host toolchains, so it's produced by a separate job/release and downloaded here
— see the workflow's "obtain apps/ide/dist/" step).

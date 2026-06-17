# Browser GUI backend for gui-lib (mred) — VERIFIED end-to-end

A `wx/wasm/` mred backend that renders Racket's `racket/gui` to an HTML canvas
in the browser. Strategy: **canvas-only** — one `<canvas>` per top-level frame,
every widget drawn by Racket via `racket/draw` onto a cairo image surface and
blitted out; controls/editors draw themselves through `dc<%>`, so editors/snips/
picts come "for free".

**Status (verified in headless Chrome via `apps/gui-demo`):** `racket/gui`
`frame%` + `canvas%` compose, instantiate, paint (cairo/pango → `<canvas>`), and
the full interactive loop works — a mouse click round-trips through the GUI event
ring → pump → frame → panel → canvas → `on-event`, and the canvas repaints on
`refresh`. **Drawn controls also work:** `button%`, `check-box%`, `message%`,
`choice%`, `gauge%`, `slider%`, `radio-box%`, `list-box%`, `group-panel%` and
`tab-panel%` lay out in a `vertical-panel%`, render themselves via `racket/draw`
onto the frame's backing surface, and (where interactive) a click fires their
callbacks. **Menus** (`menu-bar%`/`menu%`/`menu-item%`) work too — drawn and
routed by the frame (see below). **Modal dialogs** (`dialog%`) work as well: a
dialog takes over the shared canvas, blocks in a nested `yield`, and round-trips
clicks to its controls (so `message-box`/`get-text-from-user` ride along). See
`apps/gui-demo/` (a gallery demo) and `test/browser/tools/gui-demo.mjs` (the
Playwright regression driver, which opens the File menu + selects an item, clicks
the button/choice/radio-box, and opens + dismisses a modal dialog, asserting each
callback).

This directory holds the tracked backend source (the runtime clone under
`.work/` is disposable). It is wired into builds as
`package-patches/gui-lib/*.patch` (new-file diffs rooted at
`gui-lib/mred/private/wx/wasm/...`, applied by `build/consume.rkt`), plus a
selector patch to `gui-lib/mred/private/wx/platform.rkt`.

## Two bugs fixed during browser bring-up

1. **`cairo_pattern_reference` mis-bound `-> _void`** (a draw-lib FFI cast trap,
   same class as `cairo_font_options_copy`). The backing-store flush
   (`backing-draw-bm`) calls it; wasm's typed `call_indirect` trapped on the
   `(i32)->()` vs real `(i32)->i32` mismatch ("null function or function
   signature mismatch"). Fixed in
   `package-patches/draw-lib/cairo-pattern-reference.patch`. See build-wasm.md
   "Text / Pango".
2. **`resume-flush` contract** (`(->m void?)`): the backing-dc flush protocol
   calls our canvas `queue-backing-flush`/`flush`, which returned the eager
   blit's truthy result. Fixed by returning `(void)` from those methods
   (canvas.rkt).

## Event routing: frame → panel → canvas (key design point)

GTK maps each native widget pointer to its wx, so events reach the leaf widget
directly. We have no native widgets: page events arrive at the top frame tagged
with a **frame id**, so each container forwards down by **geometry**. An mred
`frame%` always has an intermediate client **panel** (`wxpanel.rkt`), so
`frame.handle-gui-event` → `panel.handle-gui-event` (hit-tests its children by
`get-x/y/width/height`, translates coordinates) → `canvas.handle-gui-event`
(builds the `mouse-event%`/`key-event%`). The panel routing was the missing link
that made clicks reach `on-event`.

## Drawn controls (button%, check-box%, message%) — verified

There are no native widgets, so a control is a logical `window%` that draws
itself. The pieces (in `control.rkt`, with hooks in `window.rkt`/`panel.rkt`/
`frame.rkt`):

- **Sizing.** Each control's `set-auto-size` measures its label with a shared
  `bitmap-dc%` (`get-text-extent`) and adds per-control chrome padding, then
  `set-size`s itself. The mred core reads that back (`make-item%` →
  `get-min-size`) so the container layout positions controls correctly.
- **Painting.** The **frame owns the backing surface**: `frame.repaint` makes a
  client-sized `bitmap%`, clears it to the panel-gray background, walks the child
  tree via `paint-self` (each container translates by child geometry; each
  control draws via `racket/draw`), pulls ARGB pixels and `canvas-blit-argb`s the
  whole surface to the page `<canvas>`. (A `canvas%` child still blits its own
  dc; controls-only and canvas-only frames are the cases used.)
- **Repaint coalescing.** A control state change (`set-label`/`set-value`/
  `enable`) calls `request-repaint`, which bubbles up the parent chain to the
  frame; the frame queues one repaint onto the eventspace so a burst of changes
  (and the post-layout settle) collapse into a single blit.
- **Activation.** A left-button release, routed down by the frame→panel geometry
  hit-test, reaches the control's `handle-gui-event`; the control fires its
  `control-event%` callback (and, for `check-box%`, toggles + repaints first).

`choice%`, `gauge%`, `slider%`, `radio-box%`, `list-box%`, `group-panel%` and
`tab-panel%` are also implemented (`controls-extra.rkt`) and verified: each
self-sizes, draws via `racket/draw`, and (where interactive) turns a
geometry-routed click into its callback. With no native popups/scrollbars we
degrade in place — a `choice%` click *cycles* to the next item (no drop-down
menu), and a `list-box%` selects the clicked row (no scrolling). The two
container controls translate their children by a client inset (group: border +
title; tab: header height) for both painting and event routing, since there is
no native client widget to carry the offset.

**Menus also work** (`menu.rkt`: `menu-bar%`, `menu%`, `menu-item%`). Menus
aren't in the window tree, so the top **frame** draws and routes them: it paints
the menu-bar strip across its top (reserving that height via
`adjust-client-delta`, and offsetting the client child below it), and on a title
click paints the open `menu%` as a popup overlay. A click on a row activates it —
firing the item callback through `frame.on-menu-command` (the same path GTK uses:
`id-to-menu-item` -> `wx->mred` -> the item's callback), toggling a checkable
item, or opening a submenu as a second overlay column. Separators, checkable
items (✓), shortcut text and submenu arrows (▸) are drawn; there is no native
popup. Right-click `popup-menu` routes through `frame.open-popup-menu`.

**Modal dialogs work** (`dialog.rkt`: `dialog%` = the shared `dialog-mixin` over
our `frame%`). The mixin gives a dialog its modal nested event loop — `(send d
show #t)` blocks in a `yield` on a close semaphore that `direct-show #f` posts —
and painting/event-routing come from `frame%` unchanged. The single page
`<canvas>` is shared, so the **topmost shown window owns it**: when a modal
dialog is up it both displays (the canvas resizes to the dialog's surface) and
**grabs all input** regardless of the frame id the page tagged events with
(`queue.rkt` `shown-windows`/`window-can-blit?` + the modal check in
`drain-gui-events!`); on close the parent frame repaints and reclaims the canvas.
Because the dialog's surface is blitted at the canvas origin, page click
coordinates already land in the dialog's space — no translation needed.
Verified in headless Chrome: a button opens a modal `dialog%`, the canvas
resizes, a click on its (stretchy) Close button fires the callback, `show`
returns, and the parent reappears. The mred core builds `message-box`,
`get-text-from-user` and the font/colour choosers on this `dialog%`, so they ride
along. (Carrying a frame id through the blit — the "real" multi-window / per-frame
canvas path — is a C-side change, deferred; today only the topmost window is
visible, so truly concurrent *non-modal* frames aren't supported.)

Still a load-bearing stub in `stubs.rkt` (method surface only): `printer-dc%`.

## What is already wired into the build (Step 1 — done, built + verified)

The runtime-level foundation is committed to the delta and is independent of
the backend's final shape:

- **`overlay/racket/src/cs/c/wasm_gui_events.c`** — a SAB record-ring for
  page→worker GUI events (mirror of the stdin ring in `wasm_shell_io.c`).
  Fixed-width 6-int32 records; `wasm_gui_events_poll(out, max)` drains them
  (non-blocking). Linked into both surfaces as a common prim (node stub
  returns 0).
- **`patches/.../build.zuo.patch`** — adds `wasm_gui_events` to
  `wasm-prim-names` and exports `_gui_events_addr/_cap/_fields` in the browser
  link's `EXPORTED_FUNCTIONS`.
- **`overlay/.../wasm_extras.inc`** — registers `wasm_gui_events_poll` as a
  foreign symbol (reachable from Racket via `vm-eval`/`foreign-procedure`).
- **`runtime-glue/shell-worker.js`** — posts the ring's base/cap/fields to the
  page in the `ready` message (`guiEvents` field).

Verified with an emsdk incremental relink: both surfaces link with
`wasm_gui_events.o`, the browser export list carries the accessors, and a node
FFI smoke test returns 0 from `wasm_gui_events_poll` on the empty ring.

## Backend scaffold (`wx-wasm/`) — thin mred backend, in progress

Strategy confirmed with the user: a **thin mred backend** — real
`window`/`frame`/`canvas`/`panel`/`dc`, everything else stubbed — gives genuine
`(require racket/gui)` + `frame%`/`canvas%` now, controls later. These files are
authored in the tracked dir and copied into the gui-lib checkout
(`mred/private/wx/wasm/`) for compile-checking; they become
`package-patches/gui-lib/` once they load under wasm.

**Compiles clean under host Racket (`raco make`):**
- **`ffi.rkt`** — foreign entry points: `canvas-blit-argb`, `gui-events-poll-raw`.
- **`dc.rkt`** — `dc%` over `backing-dc%`; `do-backing-flush` draws the backing
  bitmap into a Cairo image surface and `canvas-blit-argb`s it to the page.
- **`procs.rkt`** — the ~50 system procs (display geometry fixed at 1024×768 for
  now; fonts/colors/mouse defaults; most are no-ops).
- **`control.rkt`** — the drawn `button%`/`check-box%`/`message%` + the shared
  `control-base%` (see above).
- **`controls-extra.rkt`** — the drawn `choice%`/`gauge%`/`slider%`/
  `radio-box%`/`list-box%`/`group-panel%`/`tab-panel%`.
- **`menu.rkt`** — the drawn `menu-bar%`/`menu%`/`menu-item%`.
- **`dialog.rkt`** — the modal `dialog%` (`dialog-mixin` over `frame%`).
- **`stubs.rkt`** — `printer-dc%` as a load-bearing stub;
  `clipboard-driver%` (constructed at load) + `cursor-driver%` minimal-working.
- **`queue.rkt`** — the event pump: a frame-id→wx registry, a ~60 Hz drain of
  the ring into `queue-event` (late-bound `(send wx handle-gui-event …)`), wired
  into `yield` via `set-platform-queue-sync!`. Event-type + modifier codes that
  the page producer must mirror live here.
- **`init.rkt`** — starts the pump at load (like gtk/cocoa init.rkt).

**`platform.rkt`** (PROBE) — assembles `platform-values`; the not-yet-written
core classes (`frame`/`canvas`/`window`/`panel`/`canvas-panel`) are inline
error-on-use stubs. This probe verified (see below) that the selector +
scaffold load under the real runtime.

**Wired via `package-patches/gui-lib/`** (both dry-run + build clean):
- `01-platform-selector.patch` — `mred/private/wx/platform.rkt` `unix` branch
  picks `wx/wasm/platform.rkt` when `(getenv "PLT_WASM_GUI")` is set.
- `02-wasm-backend.patch` — creates the `wx/wasm/*.rkt` files.

### VERIFIED milestone + key finding (node, PLT_WASM_GUI)

A full build cross-compiled the backend into share.data, and on the node
surface:

    node racket.js -e '(putenv "PLT_WASM_GUI" "1")' \
                   -e '(dynamic-require (quote racket/gui/base) #f)'

- The selector picks `wx/wasm` (no more GTK FFI load) and the whole scaffold —
  `init.rkt`'s pump, `procs`, `stubs`, and the `vm-eval` foreign procedures —
  **instantiates under the real runtime**. (Set `PLT_WASM_GUI` via `putenv`
  inside Racket: Emscripten's `getenv` does NOT see the shell/`process.env`.
  For real use the worker must `setenv`/seed ENV before boot.)
- Loading then reached `wxme/editor-canvas.rkt`, which does `(inherit refresh)`
  from the platform `canvas%`. **Finding: the mred core SUBCLASSES the platform
  `canvas%`/`window%`/`frame%`/`panel%` and uses `inherit`, so their full method
  surface must exist at class-definition time** — error-on-use stubs for the
  core classes don't even let racket/gui load.

**The core (`window.rkt`/`frame.rkt`/`canvas.rkt`/`panel.rkt`) is written and
verified:** the full public method surface the core `inherit`s is present, with
lean bodies — GtkWidget FFI replaced by our logical-widget + page-`<canvas>`
model; event delivery via `handle-gui-event` → `mouse-event%`/`key-event%`.

**Page producer:** `apps/gui-demo/gui-demo.js` — canvas DOM listeners encode
mouse/key records into the ring (+`Atomics.notify`), and mirror each
`{type:"canvas"}` blit onto one persistent `<canvas>`. It boots with
`argv ["-e" "(putenv PLT_WASM_GUI 1)" "-t" main]` so the env var that selects the
wasm backend is set before `racket/gui` loads, and the program parks in
`(yield (make-semaphore))` — a Racket-level block, so the eventspace dispatch
loop keeps running the pump (the worker is not parked in a stdin read).

The demo's `racket/gui` program lives in its own readable file,
`apps/gui-demo/demo.rkt`, and `gui-demo.js` lives *outside* `public/` with a
`__PROGRAM__` token; the app's post-build hook (`build-demo.rkt`, wired via
`app.rkt`'s `hooks`) splices `demo.rkt` into the template → `dist/gui-demo.js`
(mirrors how `apps/ide` generates `ide.js` from `examples/`). Edit the demo in
`demo.rkt`, not in `dist/`.

> Build-loop cost note: `package-patches/` content feeds the build key. Adding a
> NEW patch (e.g. the draw-lib cairo fix) re-stages the affected package and
> repacks `share.data`; the SDK/base-runtime caches still hit if their inputs are
> unchanged. Editing an existing patch's content likewise re-stages just that
> package. Use the host `raco make` (methods-exist/syntax) to catch shape errors
> first; for runtime behaviour, the **node** surface (`.work/.../wasm/racket.js`
> with the freshly-packed `share.data` copied beside it) iterates far faster than
> the ~70MB browser boot.

## Idle-wake (Step 2) — resolved for the milestone, refinement deferred

How does the event pump block when idle without freezing, yet still run timers
and wake on a page event?

**Implemented in `queue.rkt`:** the pump wakes each ~16 ms (a `sync/timeout`)
and drains the ring (also drained from `yield` via `set-platform-queue-sync!`).
**Empirically confirmed in the browser:** while the main thread parks in
`(yield)`, the Racket scheduler still runs the (green) pump thread, so events
drain and dispatch — no Atomics-park needed for correctness. This costs a little
idle CPU.

The 0%-idle refinement (fold a page-pokable wake into rktio's `poll()` sleep via
`unsafe-poll-ctx-fd-wakeup` + `set-queue-wakeup!`, or `Atomics.wait`-with-timeout
on the ring tail) is future work. Note `unsafe-set-sleep-in-thread!` (Cocoa) is
out — it needs a separate OS thread and this build is `--disable-pthread`.

## Build & verify

Build the demo app (bundles `gui-lib` + `draw-lib`):

    source ~/emsdk/emsdk_env.sh
    export PATH="/opt/homebrew/bin:$PATH"          # bash 5 for wasm-deps
    racket build/main.rkt app apps/gui-demo \
      --scheme ~/oss/cz/bin/tarm64osx/scheme \
      --racket ~/oss/minimal-racket/bin/racket     # -> apps/gui-demo/dist

Verify in headless Chrome (serves dist/ with COOP/COEP, boots, screenshots the
painted frame, clicks the canvas, asserts the click round-trips + the canvas
repaints):

    cd test/browser && node tools/gui-demo.mjs --shot-prefix /tmp/gui
    # --headed to watch; screenshots at /tmp/gui-1-painted.png, -2-clicked.png

Fast inner loops while editing the backend:
- **Shape/syntax:** copy `wx-wasm/*.rkt` into the gui-lib checkout and `raco make`.
- **Runtime behaviour:** rebuild (re-stages gui-lib + repacks `share.data`), copy
  the new `apps/gui-demo/dist/share.data{,.js}` beside the node `racket.js`
  (`.work/racket/racket/src/build/cs/c/wasm/`), and pipe forms via
  `node racket.js` — seconds per cycle vs the ~70MB browser boot. Set the backend
  via `(putenv "PLT_WASM_GUI" "1")` as the FIRST form (Emscripten `getenv` does
  not see the shell/`process.env`).

Note: the app's post-build hook generates `dist/gui-demo.js` by splicing
`apps/gui-demo/demo.rkt` into the `apps/gui-demo/gui-demo.js` template — edit
those two (the demo program and the page driver), not `dist/`.

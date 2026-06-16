# WIP: browser GUI backend for gui-lib (mred)

Goal: a `wx/wasm/` mred backend that renders Racket's `racket/gui` to an
HTML canvas in the browser. Strategy (see the approved plan): **canvas-only**
— one `<canvas>` per top-level frame, every widget drawn by Racket via
`racket/draw` onto a cairo image surface and blitted out; controls/editors
draw themselves through `dc<%>`, so editors/snips/picts come "for free".

This directory holds **authored-not-yet-wired** backend source, kept in
version control because the runtime clone (`.work/`) is disposable. Once the
wake-mechanism spike (below) confirms the event-pump shape, these become
`package-patches/gui-lib/*.patch` (new-file diffs rooted at
`gui-lib/mred/private/wx/wasm/...`, applied by `build/consume.rkt`), plus a
selector patch to `gui-lib/mred/private/wx/platform.rkt`.

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
- **`stubs.rkt`** — controls/menus/dialogs/printer as error-on-use classes;
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

**Still to write (the irreducible core):**
- `window.rkt`, `frame.rkt`, `canvas.rkt`, `panel.rkt` — port the FULL public
  method surface from the GTK backend (lean bodies OK, but every method the core
  `inherit`s must be present), replacing GtkWidget FFI with our logical-widget +
  page-`<canvas>` model; event delivery via `handle-gui-event` →
  `mouse-event%`/`key-event%`. Then swap them into `platform.rkt` for the
  inline stubs. Iterate with the build→node-load loop (it pinpoints each missing
  method, e.g. `refresh`).
- Page producer (`apps/.../ide.js` or a demo page): canvas DOM listeners →
  ring records (+`Atomics.notify`); per-frame `<canvas>` for blits.

> Build-loop cost note: `package-patches/` content feeds the SDK build key, so
> editing a patch triggers a full SDK rebuild + cross-install (~10 min). Use the
> host `raco make` (methods-exist/syntax) to catch as much as possible first.

## The gating spike (Step 2) — resolve before building out the pump

How does the event pump block when idle without freezing, yet still run
timers and wake on a page event? Two findings narrowed this:

- **Cocoa's `unsafe-set-sleep-in-thread!` is out** — it runs the sleep on a
  separate OS thread, but this build is `--disable-pthread`.
- **GTK's `unsafe-poll-ctx-fd-wakeup` (via `set-queue-wakeup!`)** registers a
  fd into rktio's normal `poll()` sleep with the timer deadline folded in. It
  needs no extra thread, but depends on rktio's `poll()` actually *parking*
  the worker under Emscripten/WasmFS and on a page-pokable readable fd — the
  open empirical question.

**Decision for the first milestone (implemented in `queue.rkt`):** don't solve
idle-wake yet. The pump wakes each ~16 ms and drains the ring (also drained
from `yield`). This costs idle CPU but proves blit-out + event-in + the
backend. Swap in the 0%-idle fd-wakeup (or `Atomics.wait`-with-timeout) once
measured against a real build.

## Build & verify

    source ~/emsdk/emsdk_env.sh
    export PATH="/opt/homebrew/bin:$PATH"          # bash 5 for wasm-deps
    racket build/main.rkt apply                    # re-lay the delta into the clone
    racket build/main.rkt build \
      --scheme ~/oss/cz/bin/tarm64osx/scheme \
      --racket ~/oss/minimal-racket/bin/racket     # incremental relink + dist
    # serve dist/ and load in a SAB-capable browser

Fast inner loop while writing the backend: copy `wx-wasm/*.rkt` into
`.work/gui/gui-lib/mred/private/wx/wasm/` and `raco make` them there to catch
require/shape errors before the slow wasm build.

`gui-lib` is already staged transitively (pict-lib/rhombus-pict-lib pull it in),
so a demo app needn't add it explicitly. Set `PLT_WASM_GUI=1` in the worker so
`platform.rkt` selects `wx/wasm`.

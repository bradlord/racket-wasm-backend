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

## What is already wired into the build (Step 1 — done, pending a build)

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

## In this directory

- **`wx-wasm/gui-events.rkt`** — the Racket-side drain: wraps
  `wasm_gui_events_poll`, decodes records into `gui-evt` structs. Compiles
  clean under host Racket (instantiation needs the wasm image).

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

**Decision for the first milestone:** don't solve idle-wake yet. Use a
**periodic ~60 Hz poll** — a Racket thread (or `set-platform-queue-sync!`
driven off a timer) that wakes each ~16 ms, drains the ring with
`poll-gui-events!`, and `queue-event`s onto the target eventspace. This costs
idle CPU but proves blit-out + event-in + the backend, which is the
milestone's goal. Swap in the 0%-idle fd-wakeup (or `Atomics.wait`-with-
timeout) once measured against a real build.

## Build & verify (needs emsdk — not available in the authoring session)

    source <emsdk>/emsdk_env.sh
    racket build/main.rkt sync && racket build/main.rkt apply
    racket build/main.rkt <build subcommands>   # see build-invocation memory / build-wasm.md
    # serve dist/ and load in a SAB-capable browser (headless Chromium ok)

A demo app must pull `gui-lib` into its package set (add `gui-lib` to the app
manifest `pkgs`) for the selector patch to be staged, and set
`PLT_WASM_GUI=1` in the worker so `platform.rkt` selects `wx/wasm`.

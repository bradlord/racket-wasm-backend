#lang racket/base
;; ffi.rkt -- the wasm backend's foreign entry points.
;;
;; No dlopen under WASM: Sforeign_symbol-registered names are reached via
;; (ffi/unsafe/vm)'s vm-eval + Chez foreign-procedure, NOT ffi-lib. vm-eval
;; runs at instantiation in the wasm image (where the symbols exist); it
;; must never run during the host/cross `raco setup`, which only compiles
;; this module to .zo. See packages/web-repl/canvas.rkt and build-wasm.md.

(require ffi/unsafe/vm)

(provide canvas-blit-argb
         canvas-alloc-id
         canvas-destroy
         gui-events-poll-raw
         GUI-EVT-FIELDS)

;; The foreign procedures are bound lazily (first call), so merely requiring
;; this module -- e.g. to instantiate the backend classes on a host Racket for
;; a fast compose-class check -- does not run vm-eval against symbols that
;; only exist in the wasm image.
(define-syntax-rule (define-foreign name spec)
  (begin
    (define cached #f)
    (define (name . args)
      (unless cached (set! cached (vm-eval 'spec)))
      (apply cached args))))

;; Copy a straight-ARGB pixel buffer (racket/draw `get-argb-pixels` order)
;; out to the page, tagged with a canvas id; the page putImageData's it onto
;; the <canvas> for that id (creating it on first blit). Returns 0 in the
;; browser worker, -1 where self.postMessage is unavailable (node). A frame's
;; canvas id is its frame-id (see queue.rkt next-frame-id); id 0 is the
;; ephemeral REPL path.
(define-foreign canvas-blit-argb
  (foreign-procedure "wasm_canvas_blit_argb" (int int int u8*) int))

;; Allocate a fresh global canvas/window id (>= 1). Shared with web-repl so
;; ids never collide in the page's id->element map.
(define-foreign canvas-alloc-id
  (foreign-procedure "wasm_canvas_alloc_id" () int))

;; Tell the page to drop the <canvas> for `id` (window closed).
(define-foreign canvas-destroy
  (foreign-procedure "wasm_canvas_destroy" (int) int))

;; Must match GUI_EVT_FIELDS in racket/src/cs/c/wasm_gui_events.c.
(define GUI-EVT-FIELDS 6)

;; Drain up to max-records GUI input-event records from the page->worker ring
;; into `out` (a byte buffer of >= max-records*FIELDS*4 bytes holding LE
;; int32); returns the record count (0 if empty). Non-blocking.
(define-foreign gui-events-poll-raw
  (foreign-procedure "wasm_gui_events_poll" (u8* int) int))

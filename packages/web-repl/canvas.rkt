#lang racket/base
;; Raw pixel-buffer-to-canvas blits. Each posts { type:"canvas", id, w, h,
;; pixels } from the runtime worker to the page (racket/src/cs/c/
;; wasm_canvas.c); the page's surface renders it via putImageData. Returns 0
;; in the browser worker, -1 under node / anywhere `self.postMessage` is
;; unavailable.
;;
;; The leading `id` selects the destination canvas:
;;   id 0  -- ephemeral: the page appends a FRESH <canvas> per blit (REPL
;;            pict / bitmap printing -- see display-bm.rkt).
;;   id >0 -- addressable: the page creates the <canvas> on first blit for
;;            that id, then reuses + updates it in place. Allocate ids with
;;            `canvas-alloc-id` (a single global counter shared with the GUI
;;            backend) and tear them down with `canvas-destroy`. See
;;            window.rkt for the canvas-window API built on this.
;;
;; Three channel layouts, matching the producers callers actually have:
;;   blit-rgba -- bytes already in R G B A order (manual pixel pushing).
;;   blit-argb -- racket/draw `get-argb-pixels` output (A R G B, straight).
;;   blit-bgra -- Cairo ARGB32 memory order (B G R A, premultiplied);
;;                the C side un-premultiplies on the way out.
;; All expect w*h*4 bytes, top-down (the layout ImageData wants).

(require ffi/unsafe/vm)

(provide canvas-blit-rgba
         canvas-blit-argb
         canvas-blit-bgra
         canvas-alloc-id
         canvas-destroy)

;; No dlopen under WASM: reach Sforeign_symbol-registered names via
;; Chez foreign-procedure, not ffi-lib. vm-eval runs at instantiation
;; (in the wasm image, where the symbols exist) -- never during the
;; host/cross `raco setup` that only compiles these modules to .zo.
(define canvas-blit-rgba
  (vm-eval '(foreign-procedure "wasm_canvas_blit" (int int int u8*) int)))
(define canvas-blit-argb
  (vm-eval '(foreign-procedure "wasm_canvas_blit_argb" (int int int u8*) int)))
(define canvas-blit-bgra
  (vm-eval '(foreign-procedure "wasm_canvas_blit_bgra" (int int int u8*) int)))
(define canvas-alloc-id
  (vm-eval '(foreign-procedure "wasm_canvas_alloc_id" () int)))
(define canvas-destroy
  (vm-eval '(foreign-procedure "wasm_canvas_destroy" (int) int)))

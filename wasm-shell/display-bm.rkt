#lang racket/base
;; display-bm -- render a racket/draw `bitmap%` into the WASM browser
;; REPL's output transcript.
;;
;; Transport: the runtime worker pushes pixels to the page through
;; `wasm_canvas_blit_argb` (racket/src/cs/c/wasm_canvas.c), which
;; postMessages { type:"canvas", w, h, pixels } straight to the page.
;; `browser-shell.js`'s `appendCanvas` drops a fresh <canvas> into the
;; #output pane per blit, so drawing N bitmaps reads back as N images
;; interleaved with the session's text.
;;
;; Browser shell only. Under `node scheme.js` there is no page to
;; receive the message; the blit returns -1 and display-bm says so.
;;
;; In the REPL you can't `require` this file (it isn't in the image's
;; filesystem) -- paste the body, or preload it as a collection (see
;; build-wasm.md, "Preloading additional Racket packages").

;; racket/class for `send`; racket/draw is the caller's to require (it
;; builds the bitmap%) -- this module only invokes methods.
(require racket/class
         ffi/unsafe/vm)

(provide display-bm)

;; No dlopen under WASM: reach the Sforeign_symbol-registered primitive
;; via Chez's foreign-procedure, not ffi-lib/get-ffi-obj. See
;; build-wasm.md, "Calling WASM-specific primitives from Racket".
(define wasm-canvas-blit-argb
  (vm-eval '(foreign-procedure "wasm_canvas_blit_argb" (int int u8*) int)))

(define (display-bm bm)
  (define w (send bm get-width))
  (define h (send bm get-height))
  (define px (make-bytes (* w h 4)))
  ;; get-argb-pixels writes A R G B, non-premultiplied -- exactly the
  ;; layout wasm_canvas_blit_argb rotates to RGBA for putImageData.
  (send bm get-argb-pixels 0 0 w h px)
  (when (negative? (wasm-canvas-blit-argb w h px))
    (eprintf "display-bm: no canvas surface (not running in the browser shell?)\n"))
  (void))

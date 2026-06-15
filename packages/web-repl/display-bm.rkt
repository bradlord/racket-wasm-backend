#lang racket/base
;; display-bm -- render a racket/draw `bitmap%` into the WASM browser
;; surface. In the REPL each call drops a fresh <canvas> into the
;; #output transcript (browser-shell.js `appendCanvas`), so drawing N
;; bitmaps reads back as N inline images.
;;
;;   (require racket/draw web-repl/display-bm)  ; or just web-repl
;;   (define bm (make-bitmap 320 240))
;;   ... draw into bm ...
;;   (display-bm bm)
;;
;; Browser shell only. Under `node racket.js` there is no page to
;; receive the message; the blit returns -1 and display-bm says so.

(require racket/class           ; `send`
         "canvas.rkt")

(provide display-bm)

(define (display-bm bm)
  (define w (send bm get-width))
  (define h (send bm get-height))
  (define px (make-bytes (* w h 4)))
  ;; get-argb-pixels writes A R G B, non-premultiplied -- exactly the
  ;; layout canvas-blit-argb rotates to RGBA for putImageData.
  (send bm get-argb-pixels 0 0 w h px)
  (when (negative? (canvas-blit-argb w h px))
    (eprintf "display-bm: no canvas surface (not running in the browser shell?)\n"))
  (void))

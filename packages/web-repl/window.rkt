#lang racket/base
;; window.rkt -- an addressable drawing window for the WASM browser surface.
;;
;; Unlike display-bm.rkt (which posts each bitmap to a FRESH inline <canvas>,
;; id 0), a canvas-window owns a PERSISTENT page <canvas> keyed by a global id
;; from `canvas-alloc-id`. Draw into its dc and `canvas-window-flush!` to push
;; the pixels to that same canvas, updating it in place; `close-canvas-window`
;; tears the canvas down on the page. This is the web-repl analogue of opening a
;; window, sharing the very same id-addressed page path the racket/gui backend
;; uses (one global id space, so the two never collide).
;;
;;   (require racket/draw web-repl/window)
;;   (define win (open-canvas-window 320 240))
;;   (define dc (canvas-window-dc win))
;;   (send dc set-brush "tomato" 'solid)
;;   (send dc draw-rectangle 20 20 100 80)
;;   (canvas-window-flush! win)        ; appears / updates on the page
;;   ... draw more, flush again -> same canvas updates ...
;;   (close-canvas-window win)         ; removes the canvas
;;
;; Browser shell only. Under `node racket.js` there is no page; flush returns
;; -1 and canvas-window-flush! reports it (like display-bm).
;;
;; racket/draw's `make-bitmap`/`bitmap-dc%` are pulled via `dynamic-require` AT
;; MODULE LOAD, not a static `(require racket/draw)`: the cross `raco setup`
;; runs on a host (minimal) racket that has no draw-lib, so a static require
;; fails to compile -- exactly why display-bm.rkt/print.rkt avoid it too. The
;; runtime module resolver in the packed image (which DOES have draw-lib)
;; resolves them when this module instantiates. See web-repl/print.rkt.

(require racket/class            ; `send`, `new`
         "canvas.rkt")

(provide open-canvas-window
         canvas-window?
         canvas-window-id
         canvas-window-dc
         canvas-window-width
         canvas-window-height
         canvas-window-flush!
         close-canvas-window)

(struct canvas-window (id width height bitmap dc [closed? #:mutable]))

;; Resolved at module instantiation -- see the header note on why this is
;; dynamic-require-at-load rather than a static (require racket/draw).
(define make-bitmap (dynamic-require 'racket/draw 'make-bitmap))
(define bitmap-dc%  (dynamic-require 'racket/draw 'bitmap-dc%))

;; Allocate a fresh page canvas backed by a bitmap%/bitmap-dc% of the given
;; size. The canvas does not appear until the first canvas-window-flush!.
(define (open-canvas-window width height #:title [title #f])
  (define w (max 1 (inexact->exact (round width))))
  (define h (max 1 (inexact->exact (round height))))
  (define bm (make-bitmap w h))            ; alpha-capable
  (define dc (new bitmap-dc% [bitmap bm]))
  ;; title is accepted for forward compatibility (the page can show it as a
  ;; caption); the current page surface ignores it.
  (void title)
  (canvas-window (canvas-alloc-id) w h bm dc #f))

;; Push the current bitmap contents to the window's page <canvas>, updating it
;; in place. Returns (void); warns if there is no page surface (node).
(define (canvas-window-flush! win)
  (unless (canvas-window-closed? win)
    (define w (canvas-window-width win))
    (define h (canvas-window-height win))
    (define px (make-bytes (* w h 4)))
    ;; get-argb-pixels writes A R G B, non-premultiplied -- exactly what
    ;; canvas-blit-argb rotates to RGBA for putImageData.
    (send (canvas-window-bitmap win) get-argb-pixels 0 0 w h px)
    (when (negative? (canvas-blit-argb (canvas-window-id win) w h px))
      (eprintf "canvas-window-flush!: no canvas surface (not in the browser shell?)\n")))
  (void))

;; Remove the window's <canvas> from the page. Idempotent.
(define (close-canvas-window win)
  (unless (canvas-window-closed? win)
    (set-canvas-window-closed?! win #t)
    (canvas-destroy (canvas-window-id win)))
  (void))

#lang racket/base
;; dc.rkt -- the wasm backend drawing context.
;;
;; Far simpler than the GTK/Cocoa dc%: there are no native pixmaps or GL.
;; Everything draws into a plain Cairo image bitmap% (backing-dc%'s default
;; make-backing-bitmap), and a flush ships that bitmap's pixels to the page
;; with `canvas-blit-argb`, which putImageData's them onto the frame's
;; <canvas>. Editors/snips/picts all render through this dc<%>, so they work
;; once a canvas has one.

(require racket/class
         racket/draw/private/bitmap
         racket/draw/private/local
         racket/draw/unsafe/cairo
         "../common/backing-dc.rkt"
         "ffi.rkt")

(provide (protect-out dc%
                      do-backing-flush))

(define dc%
  (class backing-dc%
    (init [(cnvs canvas)]
          transparentish?)
    (define canvas cnvs)
    (super-new [transparent? transparentish?])

    ;; No GL surface in the browser backend (yet).
    (define/override (get-gl-context) #f)

    ;; Backing store is sized to the canvas's client area.
    (define/override (get-backing-size xb yb)
      (send canvas get-client-size xb yb))

    (define/override (get-size)
      (let ([xb (box 0)] [yb (box 0)])
        (send canvas get-virtual-size xb yb)
        (values (unbox xb) (unbox yb))))

    ;; Ask the canvas to schedule a blit of the backing store to the page.
    (define/override (queue-backing-flush)
      (send canvas queue-backing-flush))

    (define/override (flush)
      (send canvas flush))))

;; Render the dc's backing store and ship it to the page. `on-backing-flush`
;; hands us either a recorded-drawing procedure or a bitmap%; we paint it into
;; a client-sized image bitmap, pull straight-ARGB pixels, and blit.
;; `backing-draw-bm` (common/backing-dc.rkt) handles both bm shapes via a
;; throwaway cairo dc.
(define (do-backing-flush canvas dc)
  (define wb (box 0)) (define hb (box 0))
  (send canvas get-client-size wb hb)
  (define w (max 1 (unbox wb)))
  (define h (max 1 (unbox hb)))
  (send dc on-backing-flush
        (lambda (bm)
          (define target (make-object bitmap% w h #f #t))
          (define cr (cairo_create (send target get-cairo-surface)))
          (backing-draw-bm bm cr w h 0 0 1.0)
          (cairo_destroy cr)
          (define px (make-bytes (* w h 4)))
          (send target get-argb-pixels 0 0 w h px)
          (canvas-blit-argb w h px)
          (send target release-bitmap-storage))))

#lang racket/base
;; web-repl/print -- a `current-print` hook that renders bitmap values as
;; images. With it installed, a bare top-level expression (in the program
;; body or typed at the REPL) that evaluates to a bitmap% shows up as an
;; inline <canvas> via display-bm, instead of printing as
;; #<object:bitmap%>. The IDE installs this as a prelude before running
;; the user's program (see wasm-shell/ide.js).
;;
;; Duck-typed on purpose: "a bitmap" means "an object that answers
;; get-argb-pixels" -- exactly what display-bm needs. So this needs only
;; racket/class, never racket/draw, and installing it doesn't drag the
;; whole draw library into the REPL namespace.

(require racket/class
         pict/convert
         (only-in pict pict->bitmap)
         "display-bm.rkt")

(provide bitmap-like? install-bitmap-printer!)

(define (bitmap-like? v)
  (and (object? v)
       (method-in-interface? 'get-argb-pixels (object-interface v))))

;; Wrap the current `current-print` so bitmap-like results render as
;; images and everything else prints as before (the base handler also
;; suppresses void, so definitions/REPL forms that return void stay
;; quiet). Returns void.
(define (install-bitmap-printer!)
  (define base (current-print))
  (current-print
    (lambda (v)
      (cond
        [(bitmap-like? v) (display-bm v)]
        ; We do depend on pict (and draw-lib) for picts. Maybe we could dynamically require these.
        [(pict-convertible? v) (display-bm (pict->bitmap (pict-convert v)))]
        [else (base v)]))))

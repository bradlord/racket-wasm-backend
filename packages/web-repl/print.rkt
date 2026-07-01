#lang racket/base
;; web-repl/print -- a `current-print` hook that renders bitmap values as
;; images. With it installed, a bare top-level expression (in the program
;; body or typed at the REPL) that evaluates to a bitmap% shows up as an
;; inline <canvas> via display-bm, instead of printing as
;; #<object:bitmap%>. The IDE installs this as a prelude before running
;; the user's program (see apps/ide/ide.js).
;;
;; bitmap detection is duck-typed: "a bitmap" means "an object that answers
;; get-argb-pixels" -- exactly what display-bm needs, so it needs only
;; racket/class.
;;
;; pict rendering needs pict + draw-lib. We bind those entry points via
;; `dynamic-require` AT MODULE LOAD (the `define`s below run when this
;; prelude module is instantiated, before the user's program runs), NOT via
;; a static `require`. Two forces pin this design:
;;
;;   * Compile time: the single-collection `pict-balloon2` package
;;     (`(define collection "pict")`, `assume-virtual-sources #t`) shadows
;;     the `pict` collection during the cross `raco setup` that compiles
;;     this package -- a static `(require pict)` / `(require pict/convert)`
;;     resolves into pict-balloon2 (which has no such file) and errors,
;;     silently dropping print.zo from the image. `dynamic-require` is a
;;     runtime call, so compiling this module never resolves `pict`; the
;;     runtime module resolver in the packed image resolves it correctly.
;;
;;   * Runtime instantiation order: resolving these EAGERLY at load (clean
;;     REPL namespace, before the program runs) instantiates draw-lib's
;;     cairo/pango modules once, in order -- mirroring what the old static
;;     `(require pict)` did. Deferring the `dynamic-require` to print time
;;     instead trips a draw-lib init-order bug under WASM (`cairo-lock-name`
;;     referenced before cairo.rkt's instance initializes pango.rkt).
;;
;; `pict-convertible?` (from the shadowed pict/convert, loaded via
;; dynamic-require) is the predicate, not the narrower `pict?`. Rhombus
;; picts are `StaticPict` structs that satisfy `pict-convertible?` but NOT
;; `pict?`; using `pict-convertible?` + `pict-convert` handles both Racket
;; picts and Rhombus picts uniformly.

(require racket/class           ; object?, method-in-interface?, object-interface
         "display-bm.rkt")

(provide bitmap-like? install-bitmap-printer!)

(define (bitmap-like? v)
  (and (object? v)
       (method-in-interface? 'get-argb-pixels (object-interface v))))

;; Resolved at module instantiation -- see the header note on why this is
;; dynamic-require-at-load rather than a static require.
(define pict-convertible? (dynamic-require 'pict/convert 'pict-convertible?))
(define pict-convert      (dynamic-require 'pict/convert 'pict-convert))
(define pict->bitmap      (dynamic-require 'pict 'pict->bitmap))
(define pict-inset        (dynamic-require 'pict 'inset))

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
        [(pict-convertible? v)
         ;; pict-convert handles both Racket pict? and Rhombus StaticPict.
         ;; The 1px inset gives a transparent margin so a border drawn on
         ;; the pict's bounding edge (e.g. `frame`) always has a pixel
         ;; column to land in. pict->bitmap sizes the bitmap to exactly
         ;; ceiling(width) x ceiling(height), so an edge-aligned stroke
         ;; sits on the last pixel boundary; the WASM cairo build snaps it
         ;; outward and clips the right/bottom border (desktop cairo snaps
         ;; inward, so it shows there).
         (display-bm (pict->bitmap (pict-inset (pict-convert v) 1)))]
        [else (base v)]))))

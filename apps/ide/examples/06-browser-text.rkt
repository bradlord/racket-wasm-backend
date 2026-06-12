#lang racket

;; Browser-native text via Canvas 2D. racket/draw's own Pango text path
;; now works too (see the "pict text" example), but this is a lighter
;; alternative: web-repl/text asks the *page* to render text with Canvas
;; 2D and brings it back as an image -- it uses the browser's own fonts
;; (CSS font strings) instead of the bundled DejaVu Sans, with no Pango
;; layout. Handy for quick labels and any CSS-available font.

(require web-repl/text)

;; display-text blits a rendered string into the Interactions pane.
(display-text "Hello from the browser!"
              #:font "bold 32px serif" #:color "crimson")
(display-text "monospace, teal"
              #:font "20px monospace" #:color "teal")

;; Colors, sizes, and a background all work.
(display-text "white on purple"
              #:font "28px sans-serif" #:color "white"
              #:background "rebeccapurple")

;; measure-text returns the pixel size the page would use.
(define-values (w h)
  (measure-text "how wide am I?" #:font "18px sans-serif"))
(printf "measured: ~a x ~a px\n" w h)

;; NB: web-repl/text also has text->bitmap and text-pict. text-pict
;; composes with pict shapes, but rendering a bitmap-backed pict needs
;; (send dc draw-bitmap ...), which traps in this build on a separate
;; latent draw-lib FFI bug (cairo_pattern_reference) -- see the
;; wasm-text-fonts-wip branch / build-wasm.md. So this example stays
;; with the direct display helpers.

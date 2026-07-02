#lang racket
(require pict)
(provide labeled-row)

;; A row of coloured shapes with a caption.
(define shapes
  (hc-append 20
             (colorize (filled-rectangle 80 80) "crimson")
             (colorize (disk 80) "steelblue")
             (colorize (filled-ellipse 110 80) "goldenrod")))

(define (labeled-row)
  (vc-append 12
             (colorize (text "pict on Racket WASM" 'roman 22) "red")
             shapes))

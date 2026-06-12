#lang racket

;; pict builds pictures compositionally -- shapes and text are values you
;; combine with operators like hc-append (horizontal) and vc-append
;; (vertical) rather than drawing imperatively. Any pict returned to the
;; Interactions pane is rendered inline.

(require pict)

;; A row of coloured shapes.
(define shapes
  (hc-append 20
             (colorize (filled-rectangle 80 80) "crimson")
             (colorize (disk 80) "steelblue")
             (colorize (filled-ellipse 110 80) "goldenrod")))

;; Stack a text caption over the shapes. Text renders via Pango/Cairo
;; (see build-wasm.md "Browser text"); the "pict text" example does more.
(define diagram
  (vc-append 12
             (text "pict on Racket WASM" 'roman 22)
             shapes))

;; A bare pict result renders, so just evaluating it displays it.
(frame (inset diagram 20))

;; After Run, try evaluating shapes -- or (scale diagram 1.5) -- at the
;; REPL on the right.

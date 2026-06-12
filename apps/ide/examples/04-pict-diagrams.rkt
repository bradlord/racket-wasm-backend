#lang racket

;; pict builds pictures compositionally -- shapes are values you
;; combine with operators like hc-append (horizontal) and vc-append
;; (vertical) rather than drawing imperatively. Any pict returned to
;; the Interactions pane is rendered inline.
;;
;; NOTE: this example sticks to shapes -- text picts (the `text`
;; function) don't work in this WASM build. Font rendering is the
;; subject of the `wasm-text-fonts-wip` branch (see build-wasm.md);
;; it is not in this build.

(require pict)

;; A row of coloured shapes.
(define shapes
  (hc-append 20
             (colorize (filled-rectangle 80 80) "crimson")
             (colorize (disk 80) "steelblue")
             (colorize (filled-ellipse 110 80) "goldenrod")))

;; Stack the shapes over an underline bar (no text).
(define diagram
  (vc-append 12
             shapes
             (colorize (filled-rectangle 300 6) "slategray")))

;; A bare pict result renders, so just evaluating it displays it.
(frame (inset diagram 20))

;; After Run, try evaluating shapes -- or (scale diagram 1.5) -- at the
;; REPL on the right.

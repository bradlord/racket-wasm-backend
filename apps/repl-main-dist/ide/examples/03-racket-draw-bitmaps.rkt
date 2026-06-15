#lang racket

;; racket/draw renders into an offscreen bitmap%, and display-bm
;; (from the preloaded web-repl collection) blits it to the page. In
;; the Interactions pane each display-bm call appends a fresh
;; <canvas>, so drawing twice shows two images.

(require racket/draw
         web-repl/display-bm)

(define W 320) (define H 240)
(define bm (make-bitmap W H))
(define dc (send bm make-dc))
(send dc set-smoothing 'aligned)
(send dc set-brush (make-object color% 20 26 41) 'solid)
(send dc set-pen "black" 0 'transparent)
(send dc draw-rectangle 0 0 W H)
(send dc set-brush (make-object color% 242 92 56 0.9) 'solid)
(send dc draw-ellipse 50 50 120 120)
(send dc set-brush (make-object color% 51 189 237 0.85) 'solid)
(send dc draw-ellipse 130 70 140 140)
(send dc set-brush (make-object color% 252 199 46 0.85) 'solid)
(send dc draw-ellipse 120 20 80 80)

(display-bm bm)

;; A bare bitmap result also renders: after Run, try evaluating just
;; bm at the REPL on the right.

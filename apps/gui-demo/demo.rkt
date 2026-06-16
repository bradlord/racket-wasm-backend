#lang racket/gui
;; demo.rkt -- the racket/gui program the gui-demo page runs in the browser.
;;
;; This file is NOT compiled into the app; it is read verbatim by the
;; post-build hook (build-demo.rkt) and spliced into dist/gui-demo.js as the
;; program the worker requires (dropped at /tmp/main.rkt). Edit the demo here.
;;
;; It exercises the wx/wasm mred backend's *drawn controls*: a message%, a
;; button%, and a check-box% inside a vertical-panel%. Everything is rendered by
;; Racket via racket/draw onto the frame's backing surface and blitted to the
;; page <canvas>; clicks routed in from the page fire the control callbacks.
;;
;; The program parks in (yield (make-semaphore)) -- a Racket-level block, not a
;; stdin read -- so the eventspace dispatch loop keeps the event pump running.

(define frame (new frame% [label "racket/gui controls on wasm"]
                   [width 320] [height 200]))

(define panel (new vertical-panel% [parent frame]
                   [border 16] [spacing 12] [alignment '(left top)]))

(define status (new message% [parent panel] [label "clicks: 0          "]))

(define clicks 0)

(new button% [parent panel] [label "Click me"]
     [callback (lambda (b e)
                 (set! clicks (add1 clicks))
                 (printf "button clicked #~a\n" clicks)
                 (flush-output)
                 (send status set-label (format "clicks: ~a" clicks)))])

(new check-box% [parent panel] [label "Enable feature"]
     [callback (lambda (cb e)
                 (printf "check-box -> ~a\n" (send cb get-value))
                 (flush-output))])

(send frame show #t)
(printf "GUI-DEMO-READY\n")
(flush-output)
(yield (make-semaphore))

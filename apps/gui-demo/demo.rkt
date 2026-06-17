#lang racket/gui
;; demo.rkt -- the racket/gui program the gui-demo page runs in the browser.
;;
;; This file is NOT compiled into the app; it is read verbatim by the
;; post-build hook (build-demo.rkt) and spliced into dist/gui-demo.js as the
;; program the worker requires (dropped at /tmp/main.rkt). Edit the demo here.
;;
;; It exercises the wx/wasm mred backend's *drawn controls* -- everything is
;; rendered by Racket via racket/draw onto the frame's backing surface and
;; blitted to the page <canvas>; clicks routed in from the page fire the control
;; callbacks. The interactive controls verified by the Playwright driver
;; (button, choice, radio-box) are placed near the top so their hit positions
;; are deterministic (above the stretchy gauge/slider/list-box).
;;
;; The program parks in (yield (make-semaphore)) -- a Racket-level block, not a
;; stdin read -- so the eventspace dispatch loop keeps the event pump running.

(define frame (new frame% [label "racket/gui controls on wasm"]
                   [width 360] [height 580]))

;; --- menu bar (drawn across the top of the frame) ---
(define mbar (new menu-bar% [parent frame]))
(define m-file (new menu% [label "File"] [parent mbar]))
(new menu-item% [parent m-file] [label "New"]
     [callback (lambda (i e) (printf "menu: New\n") (flush-output))])
(new menu-item% [parent m-file] [label "Open"]
     [callback (lambda (i e) (printf "menu: Open\n") (flush-output))])
(new separator-menu-item% [parent m-file])
(new checkable-menu-item% [parent m-file] [label "Toggle"]
     [callback (lambda (i e) (printf "menu: Toggle ~a\n" (send i is-checked?)) (flush-output))])
(define m-edit (new menu% [label "Edit"] [parent mbar]))
(new menu-item% [parent m-edit] [label "Copy"]
     [callback (lambda (i e) (printf "menu: Copy\n") (flush-output))])

(define panel (new vertical-panel% [parent frame]
                   [border 12] [spacing 8] [alignment '(left top)]))

(define status (new message% [parent panel] [label "ready                          "]))

;; --- interactive controls (deterministic positions, top of the panel) ---
(define clicks 0)
(new button% [parent panel] [label "Click me"]
     [callback (lambda (b e)
                 (set! clicks (add1 clicks))
                 (send status set-label (format "button: ~a" clicks))
                 (printf "button clicked #~a\n" clicks) (flush-output))])

(new choice% [parent panel] [label #f] [choices '("Alpha" "Beta" "Gamma")]
     [callback (lambda (ch e)
                 (send status set-label (format "choice: ~a" (send ch get-selection)))
                 (printf "choice -> ~a\n" (send ch get-selection)) (flush-output))])

(new radio-box% [parent panel] [label #f] [choices '("One" "Two" "Three")]
     [callback (lambda (r e)
                 (send status set-label (format "radio: ~a" (send r get-selection)))
                 (printf "radio -> ~a\n" (send r get-selection)) (flush-output))])

;; --- the rest of the gallery ---
(new check-box% [parent panel] [label "Enable feature"]
     [callback (lambda (c e) (printf "check-box -> ~a\n" (send c get-value)) (flush-output))])

(define the-gauge (new gauge% [parent panel] [label #f] [range 10]))
(send the-gauge set-value 3)
(new slider% [parent panel] [label #f] [min-value 0] [max-value 10] [init-value 3]
     [callback (lambda (s e)
                 (send the-gauge set-value (send s get-value))
                 (printf "slider -> ~a\n" (send s get-value)) (flush-output))])

(new list-box% [parent panel] [label #f] [choices '("apple" "pear" "plum" "cherry")]
     [callback (lambda (lb e)
                 (printf "list -> ~a\n" (send lb get-selection)) (flush-output))])

(define grp (new group-box-panel% [parent panel] [label "Group box"]))
(new message% [parent grp] [label "a message inside the group"])

(new tab-panel% [parent panel] [choices '("Tab A" "Tab B" "Tab C")]
     [callback (lambda (t e) (printf "tab -> ~a\n" (send t get-selection)) (flush-output))])

(send frame show #t)
(printf "GUI-DEMO-READY\n")
(flush-output)
(yield (make-semaphore))

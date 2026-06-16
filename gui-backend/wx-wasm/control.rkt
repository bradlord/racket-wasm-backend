#lang racket/base
;; control.rkt -- drawn controls for the wasm backend (button%, check-box%,
;; message%).
;;
;; The wasm backend has no native widgets, so a control is a logical window%
;; that (a) measures its label to size itself (set-auto-size, read back by the
;; mred core for layout), (b) draws itself via racket/draw into the top frame's
;; backing surface (paint-self, called by the frame's repaint walk), and
;; (c) turns a left-button release routed down by frame->panel geometry into its
;; control-event% callback. State changes (set-label/set-value/enable) bubble a
;; request-repaint up to the frame, which owns the surface and blits.
;;
;; The mred core instantiates these via make-control%/make-item%, passing the
;; platform class the positional init args mirrored below (same shapes as the
;; GTK backend's button-core%/message%).

(require racket/class
         racket/draw
         "../../lock.rkt"
         "../common/queue.rkt"
         "../common/event.rkt"
         "window.rkt"
         "queue.rkt")

(provide (protect-out control-base%
                      button%
                      check-box%
                      message%))

;; --- shared measuring dc + control font ---
(define measure-bm (make-object bitmap% 1 1))
(define measure-dc (new bitmap-dc% [bitmap measure-bm]))

(define control-font (make-object font% 12 "Sans" 'default 'normal 'normal))
(define label-color (make-object color% 0 0 0))

;; Strip a single mnemonic '&' (e.g. "&Save" -> "Save"); "&&" -> "&".
(define (label->string s)
  (cond
    [(string? s) (regexp-replace* #rx"&(.)" s "\\1")]
    [(not s) ""]
    [else ""]))                      ; bitmap labels: drawn as empty for now

(define (measure str)
  (define-values (w h d a) (send measure-dc get-text-extent (if (string? str) str "") control-font))
  (values (inexact->exact (ceiling w)) (inexact->exact (ceiling h))))

;; ----------------------------------------------------------------------------

(define control-base%
  (class window%
    (init parent
          [callback void]
          [the-label ""]
          [the-font #f]
          [gtk-tag 'control])

    (super-new [parent parent] [gtk (box gtk-tag)] [no-show? #f])

    (inherit get-width get-height is-window-enabled? request-repaint
             get-eventspace set-size)

    (define label (label->string the-label))
    (define cb callback)
    (define fnt (or the-font control-font))

    (define/public (get-label) label)
    (define/public (set-label s)
      (set! label (label->string s))
      (set-auto-size)
      (request-repaint))

    ;; mred calls (command e); also our own click path uses it.
    (define/public (command e) (cb this e))

    ;; Buttons inherit set-border from here (no window decorations to toggle).
    (define/public (set-border on?) (void))

    ;; --- sizing: measure the label, plus the subclass's chrome padding ---
    ;; subclasses override label-size-extra to add room for their decoration.
    (define/public (label-size-extra) (values 16 8)) ; default: button padding
    (define/override (set-auto-size [dw 0] [dh 0])
      (define-values (tw th) (measure label))
      (define-values (ex ey) (label-size-extra))
      (set-size #f #f (max 1 (+ tw ex)) (max 1 (+ th ey))))

    ;; --- painting (subclass implements draw) ---
    (define/override (paint-self dc dx dy)
      (draw dc dx dy (get-width) (get-height)))
    (define/public (draw dc x y w h) (void))

    ;; --- click handling ---
    ;; Coordinates are already translated to this control's space by the
    ;; frame->panel geometry routing. Simple controls activate on a left
    ;; release (on-click); controls that need the hit position (radio-box,
    ;; list-box, slider) override on-mouse-down/up which receive local x,y.
    (define/override (handle-gui-event type x y k mods)
      (cond
        [(not (is-window-enabled?)) (void)]
        [(and (= type EVT-MOUSE-DOWN) (= k 0)) (on-mouse-down x y)]
        [(and (= type EVT-MOUSE-UP) (= k 0)) (on-mouse-up x y)]))
    (define/public (on-mouse-down x y) (void))
    (define/public (on-mouse-up x y) (on-click))
    (define/public (on-click) (void))
    (define/public (fire-event event-type)
      (queue-window-event
       this
       (lambda ()
         (command (new control-event%
                       [event-type event-type]
                       [time-stamp (current-milliseconds)])))))

    (define/public (get-font) fnt)

    ;; Size to the (subclass-decorated) label now, so the core's layout reads a
    ;; real min-size. Runs with the subclass's label-size-extra override active.
    (set-auto-size)))

;; ----------------------------------------------------------------------------
;; button% -- a beveled rectangle with a centered label; click fires 'button.

(define button-face (make-object color% 250 250 250))
(define button-face-down (make-object color% 220 220 220))
(define button-border (make-object color% 150 150 150))

(define button%
  (class control-base%
    (init parent cb label x y w h style font)
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'button])
    (inherit fire-event get-label get-font)

    (define pressed? #f)

    (define/override (label-size-extra) (values 24 12))

    (define/override (draw dc x y w h)
      (send dc set-pen button-border 1 'solid)
      (send dc set-brush (if pressed? button-face-down button-face) 'solid)
      (send dc draw-rounded-rectangle x y (max 1 (- w 1)) (max 1 (- h 1)) 4)
      (send dc set-text-foreground label-color)
      (send dc set-font (get-font))
      (define-values (tw th td ta) (send dc get-text-extent (get-label)))
      (send dc draw-text (get-label)
            (+ x (/ (- w tw) 2)) (+ y (/ (- h th) 2))))

    (define/override (on-click) (fire-event 'button))

    (define/public (clicked) (fire-event 'button))
    (define/public (queue-clicked) (clicked))))

;; ----------------------------------------------------------------------------
;; check-box% -- a box + optional check + label; click toggles + fires.

(define box-size 14)
(define box-pad 5)

(define check-box%
  (class control-base%
    (init parent cb label x y w h style font)
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'check-box])
    (inherit fire-event get-label get-font)

    (define value? #f)
    (define/public (get-value) value?)
    (define/public (set-value v)
      (set! value? (and v #t))
      (send this request-repaint))

    (define/override (label-size-extra) (values (+ box-size box-pad 4) 6))

    (define/override (draw dc x y w h)
      (define by (+ y (quotient (- h box-size) 2)))
      (send dc set-pen button-border 1 'solid)
      (send dc set-brush button-face 'solid)
      (send dc draw-rectangle x by box-size box-size)
      (when value?
        (send dc set-pen label-color 2 'solid)
        (send dc draw-line (+ x 3) (+ by 7) (+ x 6) (+ by 10))
        (send dc draw-line (+ x 6) (+ by 10) (+ x 11) (+ by 3)))
      (send dc set-text-foreground label-color)
      (send dc set-font (get-font))
      (define-values (tw th td ta) (send dc get-text-extent (get-label)))
      (send dc draw-text (get-label)
            (+ x box-size box-pad) (+ y (/ (- h th) 2))))

    (define/override (on-click)
      (set! value? (not value?))
      (send this request-repaint)
      (fire-event 'check-box))))

;; ----------------------------------------------------------------------------
;; message% -- a static text (or symbol-icon, drawn as its name) label.

(define message%
  (class control-base%
    (init parent label x y style font [color #f])
    (super-new [parent parent] [the-label (if (string? label) label "")]
               [the-font font] [gtk-tag 'message])
    (inherit get-label get-font)

    (define the-color (or color label-color))
    (define/public (get-color) the-color)
    (define/public (set-color c) (set! the-color (or c label-color)) (send this request-repaint))
    (define/public (set-preferred-size) (send this set-auto-size) #t)

    (define/override (label-size-extra) (values 2 2))
    (define/override (gets-focus?) #f)

    (define/override (draw dc x y w h)
      (send dc set-text-foreground the-color)
      (send dc set-font (get-font))
      (define-values (tw th td ta) (send dc get-text-extent (get-label)))
      (send dc draw-text (get-label) x (+ y (/ (- h th) 2))))))

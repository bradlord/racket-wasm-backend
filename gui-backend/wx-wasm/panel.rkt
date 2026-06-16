#lang racket/base
;; panel.rkt -- the wasm backend panel% (lean port of gtk/panel.rkt).
;;
;; A logical container: tracks its children and forwards the recursive
;; child operations the core relies on (reset/ paint/ refresh / notify). There
;; are no native child widgets, so set-child-size is a no-op (each child tracks
;; its own geometry). Borders aren't drawn yet.

(require racket/class
         "../../lock.rkt"
         "window.rkt")

(provide (protect-out panel%))

(define panel%
  (class window%
    (init parent x y w h style label)

    (define children null)
    (define lbl-pos 'horizontal)

    (super-new [parent parent]
               [gtk (box 'panel)]
               [no-show? (and (memq 'deleted style) #t)])

    (define/public (get-label-position) lbl-pos)
    (define/public (set-label-position pos) (set! lbl-pos pos))

    (define/public (adopt-child child) (send child set-parent this))

    (define/override (get-client-gtk) (box 'panel-client))
    (define/override (gets-focus?) #f)

    (define/override (reset-child-freezes)
      (super reset-child-freezes)
      (for ([child (in-list children)]) (send child reset-child-freezes)))
    (define/override (reset-child-dcs)
      (super reset-child-dcs)
      (for ([child (in-list children)]) (send child reset-child-dcs)))
    (define/override (paint-children)
      (super paint-children)
      (for ([child (in-list children)]) (send child paint-children)))
    (define/override (set-size x y w h)
      (super set-size x y w h)
      (reset-child-dcs))
    (define/override (register-child child on?)
      (let ([now-on? (and (memq child children) #t)])
        (unless (eq? on? now-on?)
          (set! children (if on? (cons child children) (remq child children))))))
    (define/override (refresh-all-children)
      (for ([child (in-list children)]) (send child refresh)))
    (define/override (notify-children-top-realize)
      (for ([child (in-list children)]) (send child notify-children-top-realize)))

    (define/public (set-item-cursor x y) (void))

    ;; Route a page input event down to the child under (x, y), translating
    ;; into the child's coordinate space. Unlike GTK (which maps each native
    ;; widget pointer to its wx directly), our events arrive at the top frame
    ;; tagged with a frame id, so each container forwards to the right child by
    ;; geometry; the recursion bottoms out at the canvas, which builds the
    ;; mouse-event%/key-event%. Children are in most-recently-added-first order,
    ;; so the first geometric match wins (good enough for overlapping panels).
    (define/override (handle-gui-event type x y k mods)
      (let loop ([cs children])
        (unless (null? cs)
          (define c (car cs))
          (define cx (send c get-x)) (define cy (send c get-y))
          (define cw (send c get-width)) (define ch (send c get-height))
          (if (and cx cy cw ch
                   (<= cx x (+ cx cw)) (<= cy y (+ cy ch)))
              (send c handle-gui-event type (- x cx) (- y cy) k mods)
              (loop (cdr cs))))))

    ;; Start with a minimum size, like the GTK panel.
    (set-size 0 0 1 1)))

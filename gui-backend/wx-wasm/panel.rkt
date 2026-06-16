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

    ;; Start with a minimum size, like the GTK panel.
    (set-size 0 0 1 1)))

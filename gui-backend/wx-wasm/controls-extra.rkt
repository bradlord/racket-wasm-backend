#lang racket/base
;; controls-extra.rkt -- the rest of the drawn controls for the wasm backend:
;; choice%, gauge%, slider%, radio-box%, list-box% (item-style, built on
;; control-base% from control.rkt) and group-panel%/tab-panel% (containers,
;; built on panel%).
;;
;; Like control.rkt's button%/check-box%/message%, each is a logical window%
;; that measures itself for layout, draws via racket/draw into the frame's
;; backing surface (paint-self), and turns geometry-routed mouse events into
;; control-event% callbacks. There are no popups/native widgets, so where a
;; platform widget would pop a menu (choice) or scroll (list-box) we degrade to
;; an in-place interaction (choice cycles; list-box selects the clicked row).
;;
;; Init arg shapes + method surfaces mirror the GTK backend's classes, since the
;; mred core instantiates and `inherit`s them identically.

(require racket/class
         racket/draw
         racket/math
         racket/list
         "../../lock.rkt"
         "../common/queue.rkt"
         "../common/event.rkt"
         "window.rkt"
         "panel.rkt"
         "control.rkt"
         "queue.rkt")

(provide (protect-out choice%
                      gauge%
                      slider%
                      radio-box%
                      list-box%
                      group-panel%
                      tab-panel%))

;; --- shared measuring dc + palette ---
(define measure-dc (new bitmap-dc% [bitmap (make-object bitmap% 1 1)]))
(define ctl-font (make-object font% 12 "Sans" 'default 'normal 'normal))
(define (text-w s) (let-values ([(w h d a) (send measure-dc get-text-extent (if (string? s) s "") ctl-font)])
                     (inexact->exact (ceiling w))))
(define (text-h) (let-values ([(w h d a) (send measure-dc get-text-extent "Ag" ctl-font)])
                   (inexact->exact (ceiling h))))

(define ink     (make-object color% 0 0 0))
(define face    (make-object color% 250 250 250))
(define border  (make-object color% 150 150 150))
(define accent  (make-object color% 70 130 200))
(define track   (make-object color% 200 200 200))
(define hilite  (make-object color% 70 130 200))
(define hilite-text (make-object color% 255 255 255))

;; ============================================================================
;; choice% -- a drop-down. No popup menu in the backend, so a click cycles to
;; the next item (wrapping) and fires 'choice. Draws the current item + a caret.

(define choice%
  (class control-base%
    (init parent cb label x y w h choices style font)
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'choice])
    (inherit fire-event get-font request-repaint set-size)

    (define items (map (lambda (s) (if (string? s) s (format "~a" s))) choices))
    (define sel (if (null? items) -1 0))

    (define/public (get-selection) sel)
    (define/public (set-selection i) (set! sel i) (request-repaint))
    (define/public (number) (length items))
    (define/public (clear) (set! items '()) (set! sel -1) (resize) (request-repaint))
    (define/public (append s)
      (set! items (append items (list (if (string? s) s (format "~a" s)))))
      (when (= sel -1) (set! sel 0))
      (resize) (request-repaint))
    (define/public (delete i)
      (set! items (for/list ([x (in-list items)] [j (in-naturals)] #:unless (= j i)) x))
      (when (>= sel (length items)) (set! sel (sub1 (length items))))
      (resize) (request-repaint))

    (define/override (on-mouse-up x y)
      (when (positive? (length items))
        (set! sel (modulo (add1 sel) (length items)))
        (request-repaint)
        (fire-event 'choice)))

    (define/override (draw dc dx dy w h)
      (send dc set-pen border 1 'solid)
      (send dc set-brush face 'solid)
      (send dc draw-rectangle dx dy (max 1 (- w 1)) (max 1 (- h 1)))
      (send dc set-font (get-font))
      (send dc set-text-foreground ink)
      (when (>= sel 0)
        (send dc draw-text (list-ref items sel) (+ dx 6) (+ dy 4)))
      ;; caret
      (define cx (+ dx w -16)) (define cy (+ dy (quotient h 2) -2))
      (send dc set-brush ink 'solid) (send dc set-pen ink 1 'solid)
      (send dc draw-polygon (list (cons cx cy) (cons (+ cx 8) cy) (cons (+ cx 4) (+ cy 5)))))

    (define (resize)
      (define widest (for/fold ([m 0]) ([s (in-list items)]) (max m (text-w s))))
      (set-size #f #f (+ widest 32) (+ (text-h) 10)))
    (resize)))

;; ============================================================================
;; gauge% -- a progress bar. value/range fraction; no interaction.

(define gauge%
  (class control-base%
    (init parent label rng x y w h style font)
    (super-new [parent parent] [the-label label] [the-font font] [gtk-tag 'gauge])
    (inherit request-repaint set-size)

    (define vertical? (and (memq 'vertical style) #t))
    (define range rng)
    (define value 0)

    (define/public (get-range) range)
    (define/public (set-range r) (set! range r) (set! value (min value r)) (request-repaint))
    (define/public (set-value v) (set! value v) (request-repaint))
    (define/public (get-value) value)

    (define/override (draw dc dx dy w h)
      (send dc set-pen border 1 'solid)
      (send dc set-brush track 'solid)
      (send dc draw-rectangle dx dy (max 1 (- w 1)) (max 1 (- h 1)))
      (define frac (if (zero? range) 0.0 (max 0.0 (min 1.0 (/ value range)))))
      (send dc set-brush accent 'solid)
      (send dc set-pen accent 1 'transparent)
      (if vertical?
          (let ([fh (inexact->exact (round (* frac (- h 2))))])
            (send dc draw-rectangle (+ dx 1) (+ dy (- h 1 fh)) (max 0 (- w 2)) fh))
          (let ([fw (inexact->exact (round (* frac (- w 2))))])
            (send dc draw-rectangle (+ dx 1) (+ dy 1) fw (max 0 (- h 2))))))

    (if vertical? (set-size #f #f 18 100) (set-size #f #f 100 18))))

;; ============================================================================
;; slider% -- a horizontal (or vertical) track with a thumb + value text.
;; init order from gtk: parent cb label val lo hi x y w style font.

(define slider%
  (class control-base%
    (init parent cb label val lo hi x y w style font)
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'slider])
    (inherit fire-event get-font request-repaint set-size get-width get-height)

    (define minv lo)
    (define maxv hi)
    (define value (max lo (min hi val)))
    (define vertical? (and (or (memq 'vertical style) (memq 'upward style)) #t))
    (define pad 8)

    (define/public (get-value) value)
    (define/public (set-value v) (set! value (max minv (min maxv v))) (request-repaint))

    (define (pos->value x w)
      (define span (max 1 (- w (* 2 pad))))
      (define f (max 0.0 (min 1.0 (/ (- x pad) span))))
      (inexact->exact (round (+ minv (* f (- maxv minv))))))

    (define/override (on-mouse-down x y)
      (define nv (if vertical?
                     (pos->value (- (get-height) y) (get-height))
                     (pos->value x (get-width))))
      (unless (= nv value) (set! value nv) (request-repaint) (fire-event 'slider)))
    (define/override (on-mouse-up x y) (void))

    (define/override (draw dc dx dy w h)
      (define span (max 1 (- (if vertical? h w) (* 2 pad))))
      (define f (if (= maxv minv) 0.0 (/ (- value minv) (- maxv minv))))
      (send dc set-pen border 1 'solid)
      (cond
        [vertical?
         (define cx (+ dx (quotient w 2)))
         (send dc draw-line cx (+ dy pad) cx (+ dy h (- pad)))
         (define ty (+ dy (- h pad (inexact->exact (round (* f span))))))
         (send dc set-brush accent 'solid)
         (send dc draw-rectangle (- cx 6) (- ty 3) 12 6)]
        [else
         (define cy (+ dy (quotient h 2)))
         (send dc draw-line (+ dx pad) cy (+ dx w (- pad)) cy)
         (define tx (+ dx pad (inexact->exact (round (* f span)))))
         (send dc set-brush accent 'solid)
         (send dc draw-rectangle (- tx 3) (- cy 8) 6 16)]))

    (if vertical? (set-size #f #f 28 120) (set-size #f #f 160 28))))

;; ============================================================================
;; radio-box% -- N labelled radio buttons; click selects + fires 'radio-box.
;; init: parent cb label x y w h labels val style font.

(define radio-circle 14)
(define radio-gap 6)

(define radio-box%
  (class control-base%
    (init parent cb label x y w h labels val style font)
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'radio-box])
    (inherit fire-event get-font request-repaint set-size)

    (define lbls (map (lambda (s) (if (string? s) s (format "~a" s))) labels))
    (define sel 0)
    (define enabled (make-vector (length lbls) #t))
    (define horizontal? (and (memq 'horizontal style) #t))
    (define item-h (+ (max radio-circle (text-h)) radio-gap))

    (define/public (clicked)
      (fire-event 'radio-box))
    (define/public (queue-clicked) (clicked))
    (define/public (button-focus i) (void))
    (define/public (set-selection i) (set! sel i) (request-repaint))
    (define/public (get-selection) sel)
    (define/public (enable-button i on?) (vector-set! enabled i (and on? #t)) (request-repaint))
    (define/public (number) (length lbls))

    ;; item top-left within the control, for hit-testing and drawing.
    (define (item-origin i w)
      (if horizontal?
          (values (* i (quotient (max 1 w) (max 1 (length lbls)))) 0)
          (values 0 (* i item-h))))
    (define (item-width w)
      (if horizontal? (quotient (max 1 w) (max 1 (length lbls))) w))

    (define/override (on-mouse-down x y)
      (for ([i (in-range (length lbls))])
        (define-values (ox oy) (item-origin i (current-w)))
        (define iw (item-width (current-w)))
        (when (and (vector-ref enabled i)
                   (<= ox x (+ ox iw)) (<= oy y (+ oy item-h)))
          (unless (= sel i)
            (set! sel i) (request-repaint) (fire-event 'radio-box)))))
    (define/override (on-mouse-up x y) (void))

    (define cur-w 0)
    (define (current-w) cur-w)

    (define/override (draw dc dx dy w h)
      (set! cur-w w)
      (send dc set-font (get-font))
      (for ([s (in-list lbls)] [i (in-naturals)])
        (define-values (ox oy) (item-origin i w))
        (define cy (+ dy oy (quotient (- item-h radio-circle) 2)))
        (send dc set-pen border 1 'solid)
        (send dc set-brush face 'solid)
        (send dc draw-ellipse (+ dx ox) cy radio-circle radio-circle)
        (when (= i sel)
          (send dc set-brush accent 'solid)
          (send dc set-pen accent 1 'solid)
          (send dc draw-ellipse (+ dx ox 4) (+ cy 4) (- radio-circle 8) (- radio-circle 8)))
        (send dc set-text-foreground (if (vector-ref enabled i) ink border))
        (send dc draw-text s (+ dx ox radio-circle radio-gap)
              (+ dy oy (quotient (- item-h (text-h)) 2)))))

    (define (resize)
      (define widest (for/fold ([m 0]) ([s (in-list lbls)])
                       (max m (+ radio-circle radio-gap (text-w s)))))
      (if horizontal?
          (set-size #f #f (* (length lbls) (+ widest 12)) item-h)
          (set-size #f #f (+ widest 6) (* (length lbls) item-h))))
    (resize)))

;; ============================================================================
;; list-box% -- a bordered list of rows; click selects a row + fires 'list-box.
;; Single-column model is implemented; columns degrade to the first column.
;; init: parent cb label kind x y w h choices style font label-font columns
;;       column-order.

(define row-h 20)

(define list-box%
  (class control-base%
    (init parent cb label kind x y w h choices style font
          [label-font #f] [columns '("")] [column-order #f])
    (super-new [parent parent] [callback cb] [the-label label] [the-font font]
               [gtk-tag 'list-box])
    (inherit fire-event get-font request-repaint set-size)

    (define multi? (and (memq kind '(multiple extended)) #t))
    (define lblfont label-font)
    (define rows (map (lambda (s) (if (string? s) s (format "~a" s))) choices))
    (define data (map (lambda (_) #f) choices))
    (define sels '())  ; list of selected indices

    (define/public (number) (length rows))
    (define/public (get-selection) (if (null? sels) -1 (car (sort sels <))))
    (define/public (get-selections) (sort sels <))
    (define/public (selected? i) (and (memv i sels) #t))
    (define/public (select i [on? #t] [extend? #t])
      (cond
        [on? (set! sels (if (or multi? extend?) (cons i (remv i sels)) (list i)))]
        [else (set! sels (remv i sels))])
      (request-repaint))
    (define/public (set-selection i) (set! sels (list i)) (request-repaint))
    (define/public (get-data i) (list-ref data i))
    (define/public (set-data i v) (set! data (list-set data i v)))
    (define/public (set-string i s [col 0])
      (set! rows (list-set rows i (if (string? s) s (format "~a" s)))) (request-repaint))
    (define/public (delete i)
      (set! rows (for/list ([x (in-list rows)] [j (in-naturals)] #:unless (= j i)) x))
      (set! data (for/list ([x (in-list data)] [j (in-naturals)] #:unless (= j i)) x))
      (set! sels (for/list ([s (in-list sels)] #:unless (= s i)) (if (> s i) (sub1 s) s)))
      (request-repaint))
    (define/public (clear) (set! rows '()) (set! data '()) (set! sels '()) (request-repaint))
    (define/public (append s [v #f])
      (set! rows (append rows (list (if (string? s) s (format "~a" s)))))
      (set! data (append data (list v)))
      (request-repaint))
    (define/public (set new-choices . _)
      (set! rows (map (lambda (s) (if (string? s) s (format "~a" s))) new-choices))
      (set! data (map (lambda (_) #f) new-choices))
      (set! sels '()) (request-repaint))
    (define/public (get-first-item) 0)
    (define/public (number-of-visible-items) (length rows))
    (define/public (set-first-visible-item i) (void))
    (define/public (queue-changed) (fire-event 'list-box))
    (define/public (queue-activated) (fire-event 'list-box-dclick))
    ;; column stubs (single-column visual model)
    (define/public (get-label-font) lblfont)
    (define/public (set-column-order o) (void))
    (define/public (get-column-order) '(0))
    (define/public (set-column-label i s) (void))
    (define/public (set-column-size i w mn mx) (void))
    (define/public (get-column-size i) (values 0 0 0))
    (define/public (append-column s) (void))
    (define/public (delete-column i) (void))
    (define/public (column-clicked i) (void))

    (define/override (on-mouse-down x y)
      (define i (quotient (max 0 (- y 1)) row-h))
      (when (< i (length rows))
        (if multi?
            (set! sels (if (memv i sels) (remv i sels) (cons i sels)))
            (set! sels (list i)))
        (request-repaint)
        (fire-event 'list-box)))
    (define/override (on-mouse-up x y) (void))

    (define/override (draw dc dx dy w h)
      (send dc set-pen border 1 'solid)
      (send dc set-brush (make-object color% 255 255 255) 'solid)
      (send dc draw-rectangle dx dy (max 1 (- w 1)) (max 1 (- h 1)))
      (send dc set-font (get-font))
      (for ([s (in-list rows)] [i (in-naturals)])
        (define ry (+ dy 1 (* i row-h)))
        (when (< ry (+ dy h))
          (cond
            [(memv i sels)
             (send dc set-brush hilite 'solid) (send dc set-pen hilite 1 'transparent)
             (send dc draw-rectangle (+ dx 1) ry (max 0 (- w 2)) row-h)
             (send dc set-text-foreground hilite-text)]
            [else (send dc set-text-foreground ink)])
          (send dc draw-text s (+ dx 4) (+ ry 2)))))

    (set-size #f #f 160 (max (* 4 row-h) 80))))

;; ============================================================================
;; group-panel% -- a container with a labelled border around its children.
;; init: parent x y w h style label.

(define group-pad 10)

(define group-panel%
  (class panel%
    (init parent x y w h style label)
    (super-new [parent parent] [x x] [y y] [w w] [h h] [style style] [label label])
    (inherit adjust-client-delta request-repaint)

    (define lbl (if (string? label) label ""))
    ;; Inset children below the title and inside the border.
    (define top (+ (text-h) 4))
    (adjust-client-delta (* 2 group-pad) (+ top group-pad))

    (define/public (set-label s) (set! lbl (if (string? s) s "")) (request-repaint))
    (define/override (gets-focus?) #f)

    ;; Children are laid out in client coords (0-based); there is no native
    ;; client widget to carry the border/title inset, so translate by it for
    ;; both painting and event routing.
    (define/override (handle-gui-event type x y k mods)
      (super handle-gui-event type (- x group-pad) (- y top) k mods))

    (define/override (paint-self dc dx dy)
      (define w (send this get-width))
      (define h (send this get-height))
      (define ty (+ dy (quotient (text-h) 2)))
      (send dc set-pen border 1 'solid)
      (send dc set-brush border 'transparent)
      (send dc draw-rectangle (+ dx 1) ty (max 1 (- w 2)) (max 1 (- h ty (- dy) 1)))
      (when (positive? (string-length lbl))
        (send dc set-font ctl-font)
        (send dc set-text-foreground ink)
        (define tw (text-w lbl))
        ;; clear a gap in the border line for the label
        (send dc set-brush (send dc get-background) 'solid)
        (send dc set-pen border 1 'transparent)
        (send dc draw-rectangle (+ dx group-pad) dy (+ tw 6) (text-h))
        (send dc set-text-foreground ink)
        (send dc draw-text lbl (+ dx group-pad 3) dy))
      ;; draw children, translated by the client inset (border + title)
      (super paint-self dc (+ dx group-pad) (+ dy top)))))

;; ============================================================================
;; tab-panel% -- a container with clickable tab headers above the content.
;; A click on a tab selects it and fires the callback; the app manages page
;; content via that callback. init: parent x y w h style labels.

(define tab-h 26)
(define tab-pad 12)

(define tab-panel%
  (class panel%
    (init parent x y w h style labels)
    (super-new [parent parent] [x x] [y y] [w w] [h h] [style style] [label #f])
    (inherit adjust-client-delta request-repaint)

    (define tabs (map (lambda (s) (if (string? s) s (format "~a" s)))
                      (if (list? labels) labels '())))
    (define sel 0)
    (define callback void)
    (define tab-rects '())  ; list of (x0 . x1) computed at draw time

    (adjust-client-delta 4 (+ tab-h 4))

    ;; --- mred tab protocol ---
    (define/public (set-callback cb) (set! callback cb))
    (define/public (swap-in . _) (void))
    (define/public (page-changed . _) (void))
    (define/public (page-reordered . _) (void))
    (define/public (on-choice-reorder . _) (void))
    (define/public (on-choice-close . _) (void))
    (define/public (queue-close-clicked . _) (void))
    (define/public (set choices)
      (set! tabs (map (lambda (s) (if (string? s) s (format "~a" s))) choices))
      (when (>= sel (length tabs)) (set! sel (max 0 (sub1 (length tabs)))))
      (request-repaint))
    (define/public (set-label i s) (set! tabs (list-set tabs i (if (string? s) s ""))) (request-repaint))
    (define/public (number) (length tabs))
    (define/public (button-focus n) (void))
    (define/override (gets-focus?) #t)
    (define/override (set-focus) (void))
    (define/public (set-selection i) (set! sel i) (request-repaint))
    (define/public (get-selection) sel)
    (define/public (delete i)
      (set! tabs (for/list ([x (in-list tabs)] [j (in-naturals)] #:unless (= j i)) x))
      (request-repaint))

    (define/override (handle-gui-event type x y k mods)
      (cond
        [(and (= type EVT-MOUSE-DOWN) (= k 0) (<= y tab-h))
         (let loop ([rs tab-rects] [i 0])
           (cond
             [(null? rs) (void)]
             [(and (>= x (caar rs)) (< x (cdar rs)))
              (unless (= i sel)
                (set! sel i) (request-repaint)
                (queue-window-event this
                                    (lambda ()
                                      (callback this (new control-event%
                                                          [event-type 'tab-panel]
                                                          [time-stamp (current-milliseconds)])))))]
             [else (loop (cdr rs) (add1 i))]))]
        ;; below the header: route into the content children as usual
        [else (super handle-gui-event type x (max 0 (- y tab-h)) k mods)]))

    (define/override (paint-self dc dx dy)
      (define w (send this get-width))
      (define h (send this get-height))
      (send dc set-font ctl-font)
      ;; tab headers
      (let loop ([ts tabs] [i 0] [tx dx] [rects '()])
        (cond
          [(null? ts) (set! tab-rects (reverse rects))]
          [else
           (define s (car ts))
           (define tw (+ (text-w s) (* 2 tab-pad)))
           (define active? (= i sel))
           (send dc set-pen border 1 'solid)
           (send dc set-brush (if active? face track) 'solid)
           (send dc draw-rectangle tx dy tw tab-h)
           (send dc set-text-foreground ink)
           (send dc draw-text s (+ tx tab-pad) (+ dy (quotient (- tab-h (text-h)) 2)))
           (loop (cdr ts) (add1 i) (+ tx tw) (cons (cons tx (+ tx tw)) rects))]))
      ;; content border
      (send dc set-pen border 1 'solid)
      (send dc set-brush border 'transparent)
      (send dc draw-rectangle (+ dx 1) (+ dy tab-h) (max 1 (- w 2)) (max 1 (- h tab-h 1)))
      ;; children, offset below the header
      (super paint-self dc dx (+ dy tab-h)))))

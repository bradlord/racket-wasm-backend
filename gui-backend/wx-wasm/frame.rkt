#lang racket/base
;; frame.rkt -- the wasm backend frame% (lean port of gtk/frame.rkt).
;;
;; A top-level window. There is no native window: a frame owns a logical
;; client area and a "frame id" that the event pump uses to route the page's
;; input records here (register-gui-window!). Native window operations
;; (resize/iconize/title/icon/decorations) reduce to state tracking; per-frame
;; <canvas> management on the page is deferred (the canvas's blit already
;; postMessages pixels to the page). The client-size-mixin behaviour is folded
;; in directly. handle-gui-event routes to the single child (the canvas).

(require racket/class
         racket/draw
         "../../lock.rkt"
         "../common/queue.rkt"
         "window.rkt"
         "queue.rkt"
         "menu.rkt"
         "ffi.rkt")

(provide (protect-out frame%))

(define all-frames (make-hasheq))

(define frame%
  (class window%
    (init parent label x y w h style)
    (init [is-dialog? #f])

    (inherit set-size get-size get-parent get-eventspace get-gtk get-x get-y
             adjust-client-delta pre-on-char pre-on-event is-shown?)

    (define floating? (and (memq 'float style) #t))
    (define frame-id (next-frame-id))

    (super-new [parent parent]
               [gtk (box 'frame)]
               [no-show? #t]
               [add-to-parent? #f])

    (set-size x y w h)

    (define saved-title (or label ""))
    (define is-modified? #f)
    (define saved-child #f)

    ;; --- client-size-mixin behaviour (folded in) ---
    (define client-x 0)
    (define client-y 0)
    (define/public (on-client-size w h) (void))
    (define/public (internal-on-client-size w h) (void))
    (define/public (save-client-size x y w h)
      (set! client-x x) (set! client-y y)
      (queue-window-event this (lambda () (internal-on-client-size w h) (on-client-size w h))))
    (define/override (get-client-delta) (values client-x client-y))

    (define/override (get-client-gtk) (box 'frame-client))
    (define/override (get-window-gtk) (get-gtk))
    (define/override (in-floating?) floating?)

    ;; Top-level: store size locally rather than asking a parent.
    (define/override (really-set-size gtk x y processed-x processed-y w h)
      (void))
    (define/override (set-child-size child-gtk x y w h) (void))

    (define/public (on-close) #t)

    ;; --- menu bar (drawn by this frame; see repaint / handle-gui-event) ---
    (define menu-bar #f)
    (define menu-bar-h 0)
    ;; open menu chain: list of (vector menu x y width), innermost-first.
    (define menu-stack '())
    ;; title hit rects of the menu-bar strip: list of (vector x0 x1 menu).
    (define title-rects '())

    (define/public (set-menu-bar mb)
      (set! menu-bar mb)
      (when mb
        (define h (send mb set-top-window this))
        (set! menu-bar-h h)
        (adjust-client-delta 0 h))
      (request-repaint))
    (define/public (get-menu-bar-wx) menu-bar)
    (define/public (reset-menu-height h)
      (set! menu-bar-h h) (adjust-client-delta 0 h) (request-repaint))

    (define/public (open-popup-menu menu x y)
      (set! menu-stack (list (vector menu x y (send menu popup-width))))
      (request-repaint))
    (define/public (close-menus)
      (unless (null? menu-stack) (set! menu-stack '()) (request-repaint)))

    (define saved-enforcements (vector 0 0 -1 -1))
    (define/public (enforce-size min-x min-y max-x max-y inc-x inc-y)
      (set! saved-enforcements (vector min-x min-y max-x max-y)))

    (define/override (get-top-win) this)
    (define/public (get-frame-id) frame-id)
    (define dc-lock #f)
    (define/public (get-dc-lock) dc-lock)
    (define/override (get-dialog-level) 0)
    (define/public (frame-relative-dialog-status win) #f)
    (define/override (get-unset-pos) #f)

    (define/override (center dir wrt)
      (let ([w-box (box 0)] [h-box (box 0)] [sw-box (box 1024)] [sh-box (box 768)])
        (get-size w-box h-box)
        (set-top-position
         (if (memq dir '(both horizontal)) (quotient (- (unbox sw-box) (unbox w-box)) 2) #f)
         (if (memq dir '(both vertical))   (quotient (- (unbox sh-box) (unbox h-box)) 2) #f))))
    (define/public (set-top-position x y) (void))

    (define/override (show on?)
      (let ([es (get-eventspace)])
        (when (and on? (eventspace-shutdown? es))
          (error 'show "eventspace has been shutdown")))
      (super show on?))

    (define/override (register-child child on?)
      (unless on? (error 'register-child-in-frame "did not expect #f"))
      (unless (or (not saved-child) (eq? child saved-child))
        (error 'register-child-in-frame "expected only one child"))
      (set! saved-child child))
    (define/override (register-child-in-parent on?) (void))
    (define/override (refresh-all-children)
      (when saved-child (send saved-child refresh))
      (request-repaint))
    (define/override (notify-children-top-realize)
      (when saved-child (send saved-child notify-children-top-realize)))

    (define/override (direct-show on?)
      (if on?
          (begin (hash-set! all-frames this #t) (register-gui-window! frame-id this)
                 (window-shown! this))
          (begin (hash-remove! all-frames this) (unregister-gui-window! frame-id)
                 (window-hidden! this)))
      (super direct-show on?)
      (when on? (request-repaint)))

    (define/public (destroy) (atomically (direct-show #f)))

    (define/augment (is-enabled-to-root?) #t)

    (define big-icon #f)
    (define small-icon #f)
    (define/public (set-icon bm [mask #f] [mode 'both])
      (case mode
        [(small) (set! small-icon bm)]
        [(big) (set! big-icon bm)]
        [(both) (set! small-icon bm) (set! big-icon bm)]))

    (define child-has-focus? #f)
    (define reported-activate #f)
    (define queued-active? #f)
    (define/public (on-focus-child on?)
      (set! child-has-focus? on?)
      (unless queued-active?
        (set! queued-active? #t)
        (queue-window-event this
                            (lambda ()
                              (let ([on? child-has-focus?])
                                (set! queued-active? #f)
                                (unless (eq? on? reported-activate)
                                  (set! reported-activate on?)
                                  (on-activate on?)))))))
    (define treat-focus-out-as-menu-click? #f)
    (define/public (treat-focus-out-as-menu-click) (set! treat-focus-out-as-menu-click? #t))
    (define/override (on-focus? on?) (on-focus-child on?) #t)
    (define/public (get-focus-window [even-if-not-active? #f]) saved-child)

    (define/override (call-pre-on-event w e) (pre-on-event w e))
    (define/override (call-pre-on-char w e) (pre-on-char w e))

    (define/override (internal-client-to-screen x y)
      (set-box! x (+ (unbox x) (get-x)))
      (set-box! y (+ (unbox y) (get-y))))

    (define/public (on-toolbar-click) (void))
    (define/public (on-menu-click) (void))
    (define/public (on-menu-command c) (void))
    (define/public (on-mdi-activate . _) (void))
    (define/public (on-activate on?) (void))
    (define/public (designate-root-frame) (void))
    (define/public (system-menu . _) (void))
    (define/public (set-modified mod?)
      (unless (eq? is-modified? (and mod? #t))
        (set! is-modified? (and mod? #t))
        (set-title saved-title)))

    (define waiting-cursor? #f)
    (define in-window #f)
    (define/public (set-wait-cursor-mode on?)
      (set! waiting-cursor? on?)
      (when in-window (send in-window enter-window)))
    (define/override (set-parent-window-cursor in-win c) (set! in-window in-win))
    (define/override (enter-window) (void))
    (define/override (leave-window) (void))
    (define/override (check-window-cursor win)
      (when in-window (send in-window enter-window)))

    (define maximized? #f)
    (define is-iconized? #f)
    (define fullscreen? #f)
    (define/public (is-maximized?) maximized?)
    (define/public (maximize on?) (set! maximized? (and on? #t)))
    (define/public (on-window-state changed value) (void))
    (define/public (iconized?) is-iconized?)
    (define/public (iconize on?) (set! is-iconized? (and on? #t)))
    (define/public (fullscreened?) fullscreen?)
    (define/public (fullscreen on?) (set! fullscreen? (and on? #t)))
    (define/public (get-menu-bar . _) #f)

    (define/public (set-title s)
      (set! saved-title s))
    (define/public (display-changed) (void))

    ;; Route a page input record. Menus (the bar strip + any open popup) are
    ;; drawn by this frame and not part of the window tree, so they intercept
    ;; events first; otherwise route into the client child, translated below the
    ;; menu-bar strip.
    (define/override (handle-gui-event type x y k mods)
      (cond
        [(not (= k 0)) (route-to-child type x y k mods)]
        [(pair? menu-stack)
         (when (= type EVT-MOUSE-DOWN) (handle-open-menu-click x y))]
        [(and menu-bar (< y menu-bar-h) (= type EVT-MOUSE-DOWN))
         (open-menu-at-title x)]
        [else (route-to-child type x y k mods)]))

    (define (route-to-child type x y k mods)
      (when saved-child
        (send saved-child handle-gui-event type x (- y menu-bar-h) k mods)))

    (define (open-menu-at-title x)
      (let loop ([rs title-rects])
        (cond
          [(null? rs) (void)]
          [(<= (vector-ref (car rs) 0) x (vector-ref (car rs) 1))
           (define menu (vector-ref (car rs) 2))
           (open-popup-menu menu (vector-ref (car rs) 0) menu-bar-h)]
          [else (loop (cdr rs))])))

    ;; Click while a menu is open: a row in some open popup activates it; a
    ;; menu-bar title switches; anything else dismisses.
    (define (handle-open-menu-click x y)
      (define hit
        (for/or ([e (in-list menu-stack)])
          (define px (vector-ref e 1)) (define py (vector-ref e 2))
          (define pw (vector-ref e 3))
          (define m (vector-ref e 0))
          (define ph (+ 2 (* (send m row-count) menu-row-height)))
          (and (<= px x (+ px pw)) (<= py y (+ py ph)) (cons e m))))
      (cond
        [hit
         (define e (car hit)) (define m (cdr hit))
         (define idx (quotient (max 0 (- y (vector-ref e 2) 1)) menu-row-height))
         (define r (send m activate-row idx))
         (cond
           [(eq? r 'closed) (set! menu-stack '()) (request-repaint)]
           [(eq? r 'stay) (request-repaint)]
           [(is-a? r menu%)
            ;; open submenu beside the row; trim any deeper open menus first
            (set! menu-stack (member e menu-stack))
            (set! menu-stack
                  (cons (vector r (+ (vector-ref e 1) (vector-ref e 3))
                                (+ (vector-ref e 2) (* idx menu-row-height))
                                (send r popup-width))
                        menu-stack))
            (request-repaint)]
           [else (void)])]
        [(and menu-bar (< y menu-bar-h)) (set! menu-stack '()) (open-menu-at-title x)]
        [else (set! menu-stack '()) (request-repaint)]))

    ;; --- drawn-control surface ---
    ;; A frame whose content is drawn controls (rather than a canvas%) owns the
    ;; backing surface: paint the whole client area into one bitmap and blit it
    ;; to the page <canvas>, walking the child tree via paint-self. (A canvas%
    ;; child still blits its own dc; a frame mixing both lets the later blit win
    ;; -- acceptable for now, controls-only and canvas-only are the cases used.)
    (define repaint-queued? #f)
    (define bg-color (make-object color% 236 236 236))
    (define mbar-bg (make-object color% 225 225 225))
    (define mborder (make-object color% 150 150 150))
    (define mhi (make-object color% 70 130 200))
    (define mwhite (make-object color% 255 255 255))
    (define mink (make-object color% 0 0 0))
    (define mgray (make-object color% 160 160 160))

    ;; Only the topmost shown window owns the single page <canvas>; a backgrounded
    ;; frame (e.g. while a modal dialog is up) skips its blit so the dialog's
    ;; surface isn't clobbered. window-hidden! repaints the new top on close.
    (define/public (repaint)
      (when (window-can-blit? this) (do-repaint)))

    (define (do-repaint)
      (define wb (box 0)) (define hb (box 0))
      (get-size wb hb)
      (define w (max 1 (unbox wb)))
      (define h (max 1 (unbox hb)))
      (define target (make-object bitmap% w h #f #t))
      (define dc (new bitmap-dc% [bitmap target]))
      (send dc set-background bg-color)
      (send dc clear)
      (when saved-child
        (send saved-child paint-self dc (send saved-child get-x)
              (+ menu-bar-h (send saved-child get-y))))
      (when menu-bar (draw-menu-bar dc w))
      (for ([e (in-list (reverse menu-stack))]) (draw-popup dc e))
      (define px (make-bytes (* w h 4)))
      (send target get-argb-pixels 0 0 w h px)
      (canvas-blit-argb w h px)
      (send dc set-bitmap #f))

    (define (draw-menu-bar dc w)
      (send dc set-pen mborder 1 'transparent)
      (send dc set-brush mbar-bg 'solid)
      (send dc draw-rectangle 0 0 w menu-bar-h)
      (send dc set-font menu-font)
      (send dc set-text-foreground mink)
      (define ty (quotient (- menu-bar-h 14) 2))
      (set! title-rects '())
      (let loop ([es (send menu-bar get-entries)] [tx 4])
        (unless (null? es)
          (define ent (car es))
          (define title (vector-ref ent 0))
          (define menu (vector-ref ent 1))
          (define-values (tw th) (measure-menu-text title))
          (define x1 (+ tx tw 16))
          (set! title-rects (append title-rects (list (vector tx x1 menu))))
          (send dc set-text-foreground (if (vector-ref ent 2) mink mgray))
          (send dc draw-text title (+ tx 8) ty)
          (loop (cdr es) x1))))

    (define (draw-popup dc e)
      (define m (vector-ref e 0))
      (define px (vector-ref e 1)) (define py (vector-ref e 2))
      (define pw (vector-ref e 3))
      (define rows (send m get-rows))
      (define ph (+ 2 (* (length rows) menu-row-height)))
      (send dc set-pen mborder 1 'solid)
      (send dc set-brush mwhite 'solid)
      (send dc draw-rectangle px py pw ph)
      (send dc set-font menu-font)
      (for ([r (in-list rows)] [i (in-naturals)])
        (define ry (+ py 1 (* i menu-row-height)))
        (cond
          [(eq? (vector-ref r 0) 'separator)
           (send dc set-pen mborder 1 'solid)
           (send dc draw-line (+ px 4) (+ ry (quotient menu-row-height 2))
                 (+ px pw -4) (+ ry (quotient menu-row-height 2)))]
          [else
           (send dc set-text-foreground (if (vector-ref r 6) mink mgray))
           (when (and (vector-ref r 4) (vector-ref r 5))   ; checkable & checked
             (send dc draw-text "✓" (+ px 5) (+ ry 3)))
           (send dc draw-text (vector-ref r 2) (+ px 22) (+ ry 3))
           (define sc (vector-ref r 3))
           (when (> (string-length sc) 0)
             (define-values (sw sh) (measure-menu-text sc))
             (send dc draw-text sc (- (+ px pw) sw 8) (+ ry 3)))
           (when (eq? (vector-ref r 0) 'submenu)
             (send dc draw-text "▸" (- (+ px pw) 14) (+ ry 3)))])))

    ;; Coalesce repaint requests: schedule one onto the eventspace so a burst of
    ;; control state changes (and the post-layout settle) collapse into a single
    ;; blit.
    (define/override (request-repaint)
      (unless repaint-queued?
        (set! repaint-queued? #t)
        (queue-window-event this
                            (lambda ()
                              (set! repaint-queued? #f)
                              (when (is-shown?) (repaint))))))))

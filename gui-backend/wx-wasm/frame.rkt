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
    (define/public (set-menu-bar mb) (void))
    (define/public (reset-menu-height h) (adjust-client-delta 0 h))

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
          (begin (hash-set! all-frames this #t) (register-gui-window! frame-id this))
          (begin (hash-remove! all-frames this) (unregister-gui-window! frame-id)))
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

    ;; Route a page input record to the single child (the canvas).
    (define/override (handle-gui-event type x y k mods)
      (when saved-child
        (send saved-child handle-gui-event type x y k mods)))

    ;; --- drawn-control surface ---
    ;; A frame whose content is drawn controls (rather than a canvas%) owns the
    ;; backing surface: paint the whole client area into one bitmap and blit it
    ;; to the page <canvas>, walking the child tree via paint-self. (A canvas%
    ;; child still blits its own dc; a frame mixing both lets the later blit win
    ;; -- acceptable for now, controls-only and canvas-only are the cases used.)
    (define repaint-queued? #f)
    (define bg-color (make-object color% 236 236 236))
    (define/public (repaint)
      (define wb (box 0)) (define hb (box 0))
      (get-size wb hb)
      (define w (max 1 (unbox wb)))
      (define h (max 1 (unbox hb)))
      (define target (make-object bitmap% w h #f #t))
      (define dc (new bitmap-dc% [bitmap target]))
      (send dc set-background bg-color)
      (send dc clear)
      (when saved-child
        (send saved-child paint-self dc (send saved-child get-x) (send saved-child get-y)))
      (define px (make-bytes (* w h 4)))
      (send target get-argb-pixels 0 0 w h px)
      (canvas-blit-argb w h px)
      (send dc set-bitmap #f))

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

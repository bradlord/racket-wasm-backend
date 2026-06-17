#lang racket/base
;; window.rkt -- the wasm backend window% (lean port of gtk/window.rkt).
;;
;; Same protocol as the GTK window% (the mred core subclasses it and uses
;; `inherit`, so the full method surface must be present), but there is no
;; GtkWidget: geometry lives in save-x/y/w/h, native show/size/focus calls are
;; no-ops, and a frame overrides the ones that must reach the page. Children
;; are positioned logically (each child tracks its own geometry), so a parent's
;; set-child-size is a no-op. `handle-gui-event` (new) is the entry point the
;; event pump calls; the base just routes to on-event/on-char via dispatch.

(require racket/class
         "../../lock.rkt"
         "../common/queue.rkt"
         "base.rkt")

(provide (protect-out window%
                      queue-window-event
                      queue-window-refresh-event))

(define (queue-window-event win thunk)
  (queue-event (send win get-eventspace) thunk))
(define (queue-window-refresh-event win thunk)
  (queue-refresh-event (send win get-eventspace) thunk))

(define window%
  (class widget%
    (init-field parent
                gtk)
    (init [no-show? #f]
          [extra-gtks null]
          [add-to-parent? #t]
          [connect-size-allocate? #t])

    (super-new [gtk gtk] [extra-gtks extra-gtks] [parent parent])

    (define save-x (get-unset-pos))
    (define save-y (get-unset-pos))
    (define save-w 0)
    (define save-h 0)

    (define/public (get-unset-pos) 0)

    (define/public (get-gtk) gtk)
    (define/public (get-client-gtk) gtk)
    (define/public (get-container-gtk) (get-client-gtk))
    (define/public (get-window-gtk) (and parent (send parent get-window-gtk)))

    (define/public (move x y) (set-size x y -1 -1))

    (define/public (set-size x y w h)
      (unless (and (or (not x) (equal? save-x x))
                   (or (not y) (equal? save-y y))
                   (or (= w -1) (= save-w (max w client-delta-w)))
                   (or (= h -1) (= save-h (max h client-delta-h))))
        (unless (not x) (set! save-x x))
        (unless (not y) (set! save-y y))
        (unless (= w -1) (set! save-w w))
        (unless (= h -1) (set! save-h h))
        (set! save-w (max save-w client-delta-w))
        (set! save-h (max save-h client-delta-h))
        (really-set-size gtk x y (or save-x 0) (or save-y 0) save-w save-h)
        (queue-on-size)))

    (define/public (save-size x y w h)
      (set! save-w w)
      (set! save-h h))

    (define/public (really-set-size gtk given-x given-y x y w h)
      (when parent (send parent set-child-size gtk x y w h)))

    ;; No native child widgets to position; children track their own geometry.
    (define/public (set-child-size child-gtk x y w h) (void))

    (define/public (remember-size x y w h)
      (unless (and (= save-w w) (= save-h h)
                   (equal? save-x x) (equal? save-y y))
        (set! save-w w) (set! save-h h)
        (set! save-x x) (set! save-y y)
        (queue-on-size)))

    (define/public (queue-on-size) (void))

    (define client-delta-w 0)
    (define client-delta-h 0)
    (define/public (adjust-client-delta dw dh)
      (set! client-delta-w dw)
      (set! client-delta-h dh))
    (define/public (infer-client-delta [w? #t] [h? #t] [sub-h-gtk #f]
                                       #:inside [inside-gtk #f])
      (when w? (set! client-delta-w 0))
      (when h? (set! client-delta-h 0)))
    (define/public (set-auto-size [dw 0] [dh 0])
      ;; No native size request; use a small default so layout has something.
      (set-size #f #f (+ 1 dw) (+ 1 dh)))

    (define shown? #f)
    (define/public (direct-show on?)
      (set! shown? (and on? #t))
      (register-child-in-parent on?)
      (when on? (reset-child-dcs)))
    (define/public (show on?) (atomically (direct-show on?)))
    (define/public (reset-child-freezes) (void))
    (define/public (reset-child-dcs) (void))
    (define/public (is-shown?) shown?)
    (define/public (is-shown-to-root?)
      (and shown? (if parent (send parent is-shown-to-root?) #t)))

    (unless no-show? (show #t))

    (define/public (get-x) (or save-x 0))
    (define/public (get-y) (or save-y 0))
    (define/public (get-width) save-w)
    (define/public (get-height) save-h)

    (define/public (get-parent) parent)
    (define/public (set-parent p)
      (set! parent p)
      (set! save-x 0)
      (set! save-y 0))

    (define/public (get-top-win) (and parent (send parent get-top-win)))
    (define/public (get-dialog-level) (if parent (send parent get-dialog-level) 0))

    (define/public (get-size xb yb)
      (set-box! xb save-w)
      (set-box! yb save-h))
    (define/public (get-client-size xb yb)
      (get-size xb yb)
      (set-box! xb (max 0 (- (unbox xb) client-delta-w)))
      (set-box! yb (max 0 (- (unbox yb) client-delta-h))))

    (define enabled? #t)
    (define/pubment (is-enabled-to-root?)
      (and enabled?
           (inner (and parent (send parent is-enabled-to-root?))
                  is-enabled-to-root?)))
    (define/public (enable on?) (set! enabled? on?))
    (define/public (is-window-enabled?) enabled?)

    (define/public (drag-accept-files on?) (void))
    (define/public (in-floating?) (and parent (send parent in-floating?)))

    ;; Register this window as the keyboard-focus target on its top frame, so
    ;; the frame routes key events here (the wasm backend has no native focus).
    ;; Also drive the core's focus machinery (on-set-focus -> caret, edit target)
    ;; since there is no native focus-in event to trigger it.
    (define/public (set-focus)
      (let ([t (get-top-win)]) (when t (send t set-key-focus this)))
      (on-set-focus))

    ;; The browser backend has no native cursors: we just track that one was set
    ;; (the handle is never rendered). NB unlike the GTK port we do NOT pull
    ;; (send (send v get-driver) get-handle): the cursor% reaching here can be the
    ;; contract-wrapped public class whose internal get-driver is hidden (the
    ;; editor sets an i-beam cursor on mouse events, which is how this surfaced).
    (define cursor-handle #f)
    (define/public (set-cursor v)
      (set! cursor-handle v)
      (check-window-cursor this))
    (define/public (enter-window) (set-window-cursor this #f))
    (define/public (leave-window) (when parent (send parent enter-window)))
    (define/public (set-window-cursor in-win c)
      (set-parent-window-cursor in-win (or c cursor-handle)))
    (define/public (set-parent-window-cursor in-win c)
      (when parent (send parent set-window-cursor in-win c)))
    (define/public (check-window-cursor win)
      (when parent (send parent check-window-cursor win)))

    (define/public (on-set-focus) (void))
    (define/public (on-kill-focus) (void))
    (define/public (focus-change on?) (void))
    (define/public (filter-key-event e) 'none)
    (define/public (on-focus? on?) #t)

    (define/private (pre-event-refresh) (void))

    (define/public (handles-events? gtk) #f)
    (define/public (dispatch-on-char e just-pre?)
      (pre-event-refresh)
      (cond
       [(other-modal? this) #t]
       [(call-pre-on-char this e) #t]
       [just-pre? #f]
       [else (when enabled? (on-char e)) #t]))
    (define/public (dispatch-on-event e just-pre?)
      (pre-event-refresh)
      (cond
       [(other-modal? this e) #t]
       [(call-pre-on-event this e) #t]
       [just-pre? #f]
       [else (when enabled? (on-event e)) #t]))

    (define/public (internal-pre-on-event gtk e) #f)
    (define/public (call-pre-on-event w e)
      (or (and parent (send parent call-pre-on-event w e)) (pre-on-event w e)))
    (define/public (call-pre-on-char w e)
      (or (and parent (send parent call-pre-on-char w e)) (pre-on-char w e)))
    (define/public (pre-on-event w e) #f)
    (define/public (pre-on-char w e) #f)
    (define/public (on-char e) (void))
    (define/public (on-event e) (void))

    ;; Entry point for the event pump; canvas% overrides to build events.
    (define/public (handle-gui-event type x y k mods) (void))

    ;; --- drawn-control painting ---
    ;; The wasm backend has no native widgets: controls (button%, message%, ...)
    ;; draw themselves into the top frame's backing surface. `paint-self` renders
    ;; this window onto `dc` at absolute client coordinates (dx, dy); the default
    ;; is a no-op (plain windows/canvases don't draw via this path -- a canvas
    ;; blits its own dc). Containers override to recurse. `request-repaint`
    ;; bubbles up to the frame, which owns the surface and schedules the blit.
    (define/public (paint-self dc dx dy) (void))
    (define/public (request-repaint)
      (when parent (send parent request-repaint)))

    (define wheel-steps-mode 'one)
    (define/public (get-wheel-steps-mode) wheel-steps-mode)
    (define/public (set-wheel-steps-mode mode) (set! wheel-steps-mode mode))

    (define skip-enter-leave? #f)
    (define/public skip-enter-leave-events
      (case-lambda
       [(skip?) (set! skip-enter-leave? skip?)]
       [else skip-enter-leave?]))

    (define/public (register-child child on?) (void))
    (define/public (register-child-in-parent on?)
      (when parent (send parent register-child this on?)))
    (define/public (paint-children) (void))
    (define/public (on-drop-file path) (void))

    (define/public (get-handle) (get-gtk))
    (define/public (get-client-handle) (get-container-gtk))

    (define/public (popup-menu m x y) (void))

    (define/public (center a b) (void))
    (define/public (refresh) (refresh-all-children))
    (define/public (refresh-all-children) (void))
    (define/public (notify-children-top-realize) (void))

    (define/public (screen-to-client x y) (internal-screen-to-client x y))
    (define/public (internal-screen-to-client x y)
      (let ([xb (box 0)] [yb (box 0)])
        (internal-client-to-screen xb yb)
        (set-box! x (- (unbox x) (unbox xb)))
        (set-box! y (- (unbox y) (unbox yb)))))
    (define/public (client-to-screen x y) (internal-client-to-screen x y))
    (define/public (internal-client-to-screen x y)
      (let-values ([(dx dy) (get-client-delta)])
        (when parent (send parent internal-client-to-screen x y))
        (set-box! x (+ (unbox x) (or save-x 0) dx))
        (set-box! y (+ (unbox y) (or save-y 0) dy))))

    (define event-position-wrt-wx #f)
    (define/public (set-event-positions-wrt wx) (set! event-position-wrt-wx wx))
    (define/public (adjust-event-position x y)
      (if event-position-wrt-wx
          (let ([xb (box x)] [yb (box y)])
            (internal-client-to-screen xb yb)
            (send event-position-wrt-wx internal-screen-to-client xb yb)
            (values (unbox xb) (unbox yb)))
          (values x y)))

    (define/public (get-client-delta) (values 0 0))
    (define/public (get-stored-client-delta) (values client-delta-w client-delta-h))
    (define/public (warp-pointer x y) (void))
    (define/public (gets-focus?) #t)))

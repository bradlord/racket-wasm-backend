#lang racket/base
;; canvas.rkt -- the wasm backend canvas% (lean version of gtk/canvas.rkt).
;;
;; Composition mirrors GTK: (canvas-mixin (class (canvas-autoscroll-mixin
;; window%) ...)). The inner platform class owns a dc% (drawing into a Cairo
;; image bitmap) and blits it to the page on flush. Scroll/combo/GL are stubbed
;; for the first milestone. handle-gui-event (called by the event pump) builds
;; mouse-event%/key-event% from the page's records and dispatches them.

(require racket/class
         racket/draw
         "../../lock.rkt"
         "../common/queue.rkt"
         "../common/canvas-mixin.rkt"
         (only-in "../common/backing-dc.rkt" queue-backing-flush)
         "../common/event.rkt"
         "window.rkt"
         "queue.rkt"
         "dc.rkt")

(provide (protect-out canvas% canvas-panel%))

(define white (make-object color% 255 255 255))

(define canvas%
  (canvas-mixin
   (class (canvas-autoscroll-mixin window%)
     (init parent x y w h style [ignored-name #f] [gl-config #f])

     (inherit get-client-size get-eventspace
              dispatch-on-event dispatch-on-char
              is-auto-scroll? reset-auto-scroll)

     (define transparent? (and (memq 'transparent style) #t))
     (define transparentish? transparent?)
     (define bg-color (if transparent? #f white))

     (define dc #f)

     (super-new [parent parent]
                [gtk (box 'canvas)]
                [no-show? (and (memq 'deleted style) #t)])

     (set! dc (new dc% [canvas this] [transparentish? transparentish?]))

     (set-size x y w h)

     ;; --- identity / kind ---
     (define/public (is-panel?) #f)
     (define/override (direct-update?) #t)
     (define/override (get-client-gtk) (box 'canvas-client))
     (define/override (get-container-gtk) (get-client-gtk))
     (define/public (reset-gl-context mapped?) (void))

     ;; --- dc / bitmaps ---
     (define/public (get-dc) dc)
     (define/public (make-compatible-bitmap w h) (send dc make-backing-bitmap w h))
     (define/public (get-scaled-client-size)
       (define wb (box 0)) (define hb (box 0))
       (get-client-size wb hb)
       (values (unbox wb) (unbox hb)))
     (define/public (get-gl-client-size) (get-scaled-client-size))

     (define/override (set-size x y w h)
       (super set-size x y w h)
       (when (and (is-auto-scroll?) (not (is-panel?))) (reset-auto-scroll))
       (on-size))

     ;; --- background ---
     (define/public (get-canvas-background) bg-color)
     (define/public (set-canvas-background c) (set! bg-color c))
     (define/public (get-canvas-background-for-backing) bg-color)
     (define/public (get-canvas-background-for-clearing) bg-color)

     ;; --- paint / flush (canvas-mixin drives queue-paint/paint-children) ---
     (define/public (queue-paint) (void))           ; overridden by canvas-mixin
     (define/public (request-canvas-flush-delay) #f)
     (define/public (cancel-canvas-flush-delay req) (void))
     (define/public (queue-canvas-refresh-event thunk)
       (queue-window-refresh-event this thunk))
     (define/public (skip-pre-paint?) #f)
     (define/public (worthwhile-to-paint?) #t)
     (define/public (on-paint) (void))
     (define/public (get-flush-window) (mcons #f #f))

     ;; Schedule the backing store to reach the page: just blit now.
     (define/public (queue-backing-flush) (do-canvas-backing-flush #f))
     (define/public (schedule-periodic-backing-flush) (void)) ; mixin extends
     (define/public (do-canvas-backing-flush ctx) (do-backing-flush this dc))
     (define/public (paint-or-queue-paint cr)
       (or (do-canvas-backing-flush cr) (begin (queue-paint) #f)))
     (define/public (flush) (do-canvas-backing-flush #f))

     (define/override (refresh) (queue-paint))
     (define/override (reset-child-dcs) (queue-paint))

     (define/public (begin-refresh-sequence) (void))
     (define/public (end-refresh-sequence) (void))

     (define/public (on-size) (void))
     (define/public (on-client-size w h) (void))

     ;; --- scrolling (stubbed for the milestone) ---
     (define/override (do-set-scrollbars h-step v-step h-len v-len h-page v-page h-pos v-pos) (void))
     (define/override (reset-dc-for-autoscroll) (void))
     (define/override (get-virtual-h-pos) 0)
     (define/override (get-virtual-v-pos) 0)
     (define/public (show-scrollbars h? v?) (void))
     (define/public (deliver-scroll-callbacks?) #f)
     (define/public (set-scroll-page which v) (void))
     (define/public (set-scroll-range which v) (void))
     (define/public (set-scroll-pos which v) (void))
     (define/public (get-scroll-page which) 1)
     (define/public (get-scroll-range which) 0)
     (define/public (get-scroll-pos which) 0)
     (define/public (do-scroll dir) (void))
     (define/public (on-scroll e) (void))
     (define/public (scroll x y) (void))
     (define/public (set-resize-corner on?) (void))

     ;; --- collecting blits (caret flashing) ---
     (define/public (register-collecting-blit x y w h on off on-x on-y off-x off-y) (void))
     (define/public (unregister-collecting-blits) (void))

     ;; --- combo (unsupported) ---
     (define/public (clear-combo-items) (void))
     (define/public (append-combo-item s) (void))
     (define/public (on-popup) (void))
     (define/public (combo-maybe-clicked) (void))
     (define/public (on-combo-select i) (void))
     (define/public (set-combo-text s) (void))
     (define/public (popup-combo) (void))

     (define/override (handles-events? gtk) #t)
     (define/override (internal-pre-on-event gtk e) #f)

     ;; --- page input -> eventspace events ---
     (define/override (handle-gui-event type x y k mods)
       (define (mod m) (positive? (bitwise-and mods m)))
       (cond
        [(or (= type EVT-MOUSE-DOWN) (= type EVT-MOUSE-UP)
             (= type EVT-MOUSE-MOVE) (= type EVT-ENTER) (= type EVT-LEAVE))
         (define et
           (cond
            [(= type EVT-MOUSE-MOVE) 'motion]
            [(= type EVT-ENTER) 'enter]
            [(= type EVT-LEAVE) 'leave]
            [(= type EVT-MOUSE-DOWN) (case k [(1) 'middle-down] [(2) 'right-down] [else 'left-down])]
            [else (case k [(1) 'middle-up] [(2) 'right-up] [else 'left-up])]))
         (define e
           (new mouse-event%
                [event-type et]
                [left-down (case et [(left-down) #t] [(left-up) #f] [else (= k 0)])]
                [middle-down (case et [(middle-down) #t] [(middle-up) #f] [else #f])]
                [right-down (case et [(right-down) #t] [(right-up) #f] [else #f])]
                [x x] [y y]
                [shift-down (mod MOD-SHIFT)]
                [control-down (mod MOD-CONTROL)]
                [meta-down (mod MOD-META)]
                [alt-down (mod MOD-ALT)]))
         (dispatch-on-event e #f)]
        [(= type EVT-KEY-DOWN)
         (define e
           (new key-event%
                [key-code (if (and (> k 0) (< k #x110000)) (integer->char k) #\nul)]
                [x x] [y y]
                [shift-down (mod MOD-SHIFT)]
                [control-down (mod MOD-CONTROL)]
                [meta-down (mod MOD-META)]
                [alt-down (mod MOD-ALT)]))
         (dispatch-on-char e #f)]
        [else (void)])))))

;; canvas-panel%: a canvas that is also a container (panel). Tracks children
;; and forwards the recursive child operations, like panel%.
(define canvas-panel%
  (class canvas%
    (define children null)
    (super-new)
    (define/override (is-panel?) #t)
    (define/public (get-label-position) 'horizontal)
    (define/public (set-label-position pos) (void))
    (define/public (adopt-child child) (send child set-parent this))
    (define/public (set-item-cursor x y) (void))
    (define/override (register-child child on?)
      (let ([now-on? (and (memq child children) #t)])
        (unless (eq? on? now-on?)
          (set! children (if on? (cons child children) (remq child children))))))
    (define/override (reset-child-freezes)
      (super reset-child-freezes)
      (for ([c (in-list children)]) (send c reset-child-freezes)))
    (define/override (paint-children)
      (super paint-children)
      (for ([c (in-list children)]) (send c paint-children)))
    (define/override (refresh-all-children)
      (for ([c (in-list children)]) (send c refresh)))
    (define/override (notify-children-top-realize)
      (for ([c (in-list children)]) (send c notify-children-top-realize)))))

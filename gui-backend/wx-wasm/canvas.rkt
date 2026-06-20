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
              dispatch-on-event dispatch-on-char set-focus request-repaint
              is-auto-scroll? reset-auto-scroll)

     (define transparent? (and (memq 'transparent style) #t))
     (define transparentish? transparent?)
     (define bg-color (if transparent? #f white))

     (define dc #f)

     ;; Persistent compositing bitmap (opaque canvases only). The frame rebuilds
     ;; its whole surface every repaint and editors do *partial* redraws, so the
     ;; transient backing only holds the last-redrawn region. We fold each flush's
     ;; backing into this client-sized bitmap (kept across flushes) and blit the
     ;; whole thing in paint-self, so partial line redraws accumulate instead of
     ;; blanking the rest of a multiline buffer. Initialised opaque to bg-color so
     ;; undrawn areas show the canvas background, not the frame grey.
     (define composite-bm #f)
     (define composite-dc #f)
     (define comp-w 0)
     (define comp-h 0)

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

     ;; Unified compositing: a canvas does NOT blit to the page on its own (that
     ;; clobbers the frame's whole-surface blit when controls + a canvas share a
     ;; frame). Instead it requests a frame repaint; the frame's repaint walks
     ;; paint-self (below), which draws this canvas's recorded content into the
     ;; frame surface, and the frame does the single blit. These feed dc%'s flush
     ;; protocol (resume-flush/flush are `(->m void?)`), so they return void.
     (define/public (queue-backing-flush) (request-repaint) (void))
     (define/public (schedule-periodic-backing-flush) (void)) ; mixin extends
     (define/public (do-canvas-backing-flush ctx) (request-repaint) #f)
     (define/public (paint-or-queue-paint cr)
       (or (do-canvas-backing-flush cr) (begin (queue-paint) #f)))
     (define/public (flush) (request-repaint) (void))

     ;; (Re)allocate the composite bitmap when the client size changes, filling
     ;; it opaque with the canvas background.
     (define/private (ensure-composite w h)
       (unless (and composite-bm (= comp-w w) (= comp-h h))
         (when composite-dc (send composite-dc set-bitmap #f))
         (define bm (make-object bitmap% w h #f #t))
         (define cdc (new bitmap-dc% [bitmap bm]))
         (when bg-color
           (send cdc set-brush bg-color 'solid)
           (send cdc set-pen bg-color 1 'transparent)
           (send cdc draw-rectangle 0 0 w h))
         (set! composite-bm bm)
         (set! composite-dc cdc)
         (set! comp-w w)
         (set! comp-h h)))

     ;; Draw this canvas's content onto the frame's surface at (dx, dy). GTK
     ;; clears each canvas to its background in its own draw handler; we have no
     ;; per-canvas expose -- the frame clears the whole surface to grey (236) and
     ;; composites children here -- so we keep our own persistent composite (see
     ;; above) and blit that. Fold the latest backing (often a partial line
     ;; redraw) into the composite first; transparent areas of the fresh backing
     ;; leave prior content intact, so siblings of the redrawn line persist.
     (define/override (paint-self fdc dx dy)
       (define wb (box 0)) (define hb (box 0))
       (get-client-size wb hb)
       (define w (max 1 (unbox wb)))
       (define h (max 1 (unbox hb)))
       (cond
         [transparent?
          ;; transparent canvas: composite the backing directly so what's beneath
          ;; shows through (no opaque background to accumulate onto).
          (paint-backing-onto dc fdc dx dy w h)]
         [else
          (ensure-composite w h)
          (paint-backing-onto dc composite-dc 0 0 w h)
          (send fdc draw-bitmap composite-bm dx dy)]))

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
         ;; Clicking a canvas gives it the keyboard focus (so key events route
         ;; here -- see frame.handle-gui-event). Editors need this to type.
         (when (= type EVT-MOUSE-DOWN) (set-focus))
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

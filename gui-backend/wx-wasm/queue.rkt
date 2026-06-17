#lang racket/base
;; queue.rkt -- the wasm backend event pump.
;;
;; The page produces GUI input records into the SAB ring (wasm_gui_events.c);
;; this pump drains them and turns them into eventspace events. For the first
;; milestone the pump does NOT idle-wake: it wakes ~60 times/second (a 16ms
;; sync timeout) and drains the ring each time. (0%-idle wake via
;; unsafe-poll-ctx-fd-wakeup / Atomics.wait-with-timeout is a later
;; refinement -- see gui-backend/README.md.) Draining is also wired into
;; yield via set-platform-queue-sync!.
;;
;; Dispatch is late-bound: a window registers itself under a small integer
;; "frame id" that the page tags its events with; the pump looks the wx up and
;; calls (send wx handle-gui-event ...). Using `send` (not a static require)
;; keeps queue.rkt free of a dependency cycle with window/frame/canvas.

(require racket/class
         "../common/queue.rkt"
         "ffi.rkt")

(provide (protect-out wasm-start-event-pump
                      register-gui-window!
                      unregister-gui-window!
                      next-frame-id
                      window-shown!
                      window-hidden!
                      window-can-blit?
                      ;; event type codes (mirror in the page producer JS):
                      EVT-MOUSE-DOWN EVT-MOUSE-UP EVT-MOUSE-MOVE
                      EVT-KEY-DOWN EVT-KEY-UP EVT-RESIZE
                      EVT-ENTER EVT-LEAVE EVT-WHEEL
                      MOD-SHIFT MOD-CONTROL MOD-ALT MOD-META)
         ;; re-exports from common/queue:
         current-eventspace
         queue-event
         yield)

;; Event type codes -- must match racket/src/cs/c/wasm_gui_events.c usage and
;; the page producer in ide.js.
(define EVT-MOUSE-DOWN 1)
(define EVT-MOUSE-UP   2)
(define EVT-MOUSE-MOVE 3)
(define EVT-KEY-DOWN   4)
(define EVT-KEY-UP     5)
(define EVT-RESIZE     6)
(define EVT-ENTER      7)
(define EVT-LEAVE      8)
(define EVT-WHEEL      9)

(define MOD-SHIFT   1)
(define MOD-CONTROL 2)
(define MOD-ALT     4)
(define MOD-META    8)

;; frame-id -> wx object (a frame%, which routes to its canvas).
(define windows (make-hasheqv))
(define frame-id-counter 0)
(define (next-frame-id)
  (set! frame-id-counter (add1 frame-id-counter))
  frame-id-counter)
(define (register-gui-window! id wx) (hash-set! windows id wx))
(define (unregister-gui-window! id) (hash-remove! windows id))

;; z-order of shown top-level windows (most-recently-shown first). The page has
;; a SINGLE <canvas>, so only the topmost shown window is displayed; and if that
;; window is modal (a dialog%, dialog-level > 0) it also GRABS all input,
;; regardless of the frame id the page tagged events with. That is what lets a
;; modal dialog -- which is a second frame% with its own id -- take over the
;; canvas and round-trip clicks without per-frame canvases or a frame-tagged
;; blit. (Carrying a frame id through the blit -- the "real" multi-window path --
;; is a C-side change; deferred. Stacked modals work; truly concurrent non-modal
;; frames don't -- only the top one is visible.)
(define shown-windows '())
(define (window-shown! wx)
  (set! shown-windows (cons wx (remq wx shown-windows))))
(define (window-hidden! wx)
  (set! shown-windows (remq wx shown-windows))
  ;; whoever is now on top reclaims the canvas
  (let ([t (and (pair? shown-windows) (car shown-windows))])
    (when t (send t request-repaint))))
(define (display-top-window) (and (pair? shown-windows) (car shown-windows)))
;; Only the topmost shown window may paint to the (single) canvas.
(define (window-can-blit? wx)
  (let ([t (display-top-window)]) (or (not t) (eq? t wx))))

;; Scratch buffer for a batch of records (reused across drains).
(define MAX-BATCH 64)
(define batch-buf (make-bytes (* MAX-BATCH GUI-EVT-FIELDS 4)))

(define (rec-field r f)
  (define base (* (+ (* r GUI-EVT-FIELDS) f) 4))
  (integer-bytes->integer batch-buf #t #f base (+ base 4)))

;; Drain all pending records and queue them onto their target eventspaces.
;; Called from the pump thread and from yield (set-platform-queue-sync!).
(define (drain-gui-events!)
  (let loop ()
    (define n (gui-events-poll-raw batch-buf MAX-BATCH))
    (when (> n 0)
      (for ([r (in-range n)])
        (define type  (rec-field r 0))
        (define id    (rec-field r 1))
        (define x     (rec-field r 2))
        (define y     (rec-field r 3))
        (define k     (rec-field r 4))
        (define mods  (rec-field r 5))
        ;; A modal window on top grabs input; otherwise route by the tagged id.
        (define top (display-top-window))
        (define wx
          (if (and top (positive? (send top get-dialog-level)))
              top
              (hash-ref windows id #f)))
        (when wx
          (define es (send wx get-eventspace))
          (queue-event es
                       (lambda ()
                         (send wx handle-gui-event type x y k mods)))))
      ;; If we filled the batch there may be more; keep going.
      (when (= n MAX-BATCH) (loop)))))

(set-check-queue! (lambda () #f))
(set-platform-queue-sync! (lambda () (drain-gui-events!)))

;; The pump: wake each ~16ms (or sooner on a Racket-side event) and drain.
(define (wasm-start-event-pump)
  (thread
   (lambda ()
     (let loop ()
       (sync/timeout 0.016 queue-evt boundary-tasks-ready-evt)
       (pre-event-sync #t)
       (drain-gui-events!)
       (loop)))))

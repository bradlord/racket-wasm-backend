#lang racket/base
;; gui-events.rkt -- read GUI input events out of the page->worker ring.
;;
;; The page (ide.js / a demo page) writes fixed-width records into the
;; SAB ring defined in racket/src/cs/c/wasm_gui_events.c; this module
;; drains them on the worker. `wasm_gui_events_poll(out, max-records)`
;; copies up to max-records records into a caller buffer of int32 and
;; returns the count (non-blocking). Each record is `fields` int32:
;;
;;   [0] type   (one of the evt:* codes below)
;;   [1] frame  (target frame/canvas id)
;;   [2] x      (mouse x; resize: width)
;;   [3] y      (mouse y; resize: height)
;;   [4] k      (button code / key code / wheel delta)
;;   [5] mods   (modifier bitmask: shift=1 ctrl=2 alt=4 meta=8)
;;
;; Like packages/web-repl/canvas.rkt, the foreign symbol is reached via
;; (ffi/unsafe/vm)'s vm-eval + Chez foreign-procedure -- there is no
;; dlopen under WASM. vm-eval runs at instantiation in the wasm image
;; (where wasm_gui_events_poll is registered by wasm_extras.inc); it must
;; never run during the host/cross `raco setup`, which only compiles this
;; module to .zo and does not instantiate it.

(require ffi/unsafe/vm)

(provide (struct-out gui-evt)
         GUI-EVT-FIELDS
         evt:mouse-down evt:mouse-up evt:mouse-move
         evt:key-down   evt:key-up
         evt:resize     evt:enter evt:leave evt:wheel
         mod-shift mod-control mod-alt mod-meta
         poll-gui-events!)

;; Must match GUI_EVT_FIELDS in wasm_gui_events.c.
(define GUI-EVT-FIELDS 6)

;; Event type codes (page and worker must agree; mirror in the page JS).
(define evt:mouse-down 1)
(define evt:mouse-up   2)
(define evt:mouse-move 3)
(define evt:key-down   4)
(define evt:key-up     5)
(define evt:resize     6)
(define evt:enter      7)
(define evt:leave      8)
(define evt:wheel      9)

(define mod-shift   1)
(define mod-control 2)
(define mod-alt     4)
(define mod-meta    8)

(struct gui-evt (type frame x y k mods) #:transparent)

;; Bound at instantiation, in the wasm image. Signature: fill `out`
;; (a byte buffer holding max-records*FIELDS little-endian int32) and
;; return the number of records written.
(define wasm-gui-events-poll
  (vm-eval '(foreign-procedure "wasm_gui_events_poll" (u8* int) int)))

;; Read up to `max-records` events, newest-last, as a list of gui-evt.
;; Returns '() when the ring is empty. Allocates a scratch buffer per
;; call sized to max-records; callers that poll hot should hoist it.
(define (poll-gui-events! [max-records 64])
  (define fields GUI-EVT-FIELDS)
  (define buf (make-bytes (* max-records fields 4)))
  (define n (wasm-gui-events-poll buf max-records))
  (for/list ([r (in-range n)])
    (define base (* r fields 4))
    (define (i32 f) (integer-bytes->integer buf #t #f (+ base (* f 4)) (+ base (* f 4) 4)))
    (gui-evt (i32 0) (i32 1) (i32 2) (i32 3) (i32 4) (i32 5))))

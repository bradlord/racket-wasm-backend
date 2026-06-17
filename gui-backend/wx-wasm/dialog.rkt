#lang racket/base
;; dialog.rkt -- the wasm backend dialog% (a modal top-level window).
;;
;; A dialog is just a frame% wrapped in the shared dialog-mixin
;; (common/dialog.rkt): the mixin makes `show #t` block in `yield` on a close
;; semaphore that `direct-show #f` posts, which is what gives a modal dialog its
;; nested event loop. There is nothing platform-specific to do beyond that --
;; the GTK backend's native bits (window type hint, transient-for, centering)
;; have no analogue here, so we drop them. Painting + event routing come from
;; frame% unchanged (the dialog draws its child controls onto the backing
;; surface and routes clicks like any frame), and the eventspace keeps pumping
;; page input while the worker is parked in the nested yield -- the same
;; parked-worker/page-pumps-events path the menus and controls already rely on.
;;
;; The mred core builds message-box / get-text-from-user / the font+color
;; choosers on top of this dialog%, so they come along once it is real.

(require racket/class
         "../common/dialog.rkt"
         "frame.rkt")

(provide (protect-out dialog%))

(define dialog%
  (class (dialog-mixin frame%)
    (super-new [is-dialog? #t])))

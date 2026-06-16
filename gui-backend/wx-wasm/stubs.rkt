#lang racket/base
;; stubs.rkt -- placeholder platform classes for the wasm backend.
;;
;; The first milestone is frame% + canvas% + dc%. Controls, menus, dialogs and
;; the printer dc are not implemented. The mred core SUBCLASSES the platform
;; control classes at module load (wxitem.rkt builds make-control% over item%,
;; etc.) and uses `inherit`, so these can't be bare object% stubs: item% and
;; the controls extend window% (and dialog% extends frame%) to expose the
;; required method surface so racket/gui composes/loads. They are not
;; instantiated in the milestone; creating one yields a degenerate, non-
;; functional widget (controls aren't supported yet). clipboard-driver% and
;; cursor-driver% ARE constructed (the former at load), so they are real.

(require racket/class
         (only-in "../common/backing-dc.rkt" backing-dc%)
         "window.rkt"
         "frame.rkt")

(provide (protect-out clipboard-driver%
                      cursor-driver%
                      printer-dc%
                      button%
                      check-box%
                      choice%
                      gauge%
                      group-panel%
                      list-box%
                      message%
                      radio-box%
                      slider%
                      tab-panel%
                      item%
                      menu%
                      menu-bar%
                      menu-item%
                      dialog%))

;; item% carries the full window% surface so the core's make-item%/make-control%
;; (which subclass it at load) can inherit window methods.
(define item%
  (class window%
    (super-new)
    (define/public (get-label) "")
    (define/public (set-label s) (void))
    (define/public (get-label-gtk) (get-gtk))
    (inherit get-gtk)
    (define/public (command e) (void))
    ;; Methods the core inherits from platform controls at load (wxitem.rkt).
    (define/public (set-border on?) (void))
    (define/public (set-value v) (void))
    (define/public (get-value) 0)))

;; Controls extend item% (compose only; not instantiated in the milestone).
;; They carry the GTK method names the core inherits at load.
(define button% (class item% (super-new)))
(define check-box% (class item% (super-new)))
(define group-panel% (class item% (super-new)))
(define slider% (class item% (super-new)))

(define choice%
  (class item%
    (super-new)
    (define/public (set-selection i) (void))
    (define/public (get-selection) 0)
    (define/public (number) 0)
    (define/public (clear) (void))
    (define/public (delete i) (void))
    (define/public (append s) (void))))

(define gauge%
  (class item%
    (super-new)
    (define/public (get-range) 1)
    (define/public (set-range v) (void))))

(define radio-box%
  (class item%
    (super-new)
    (define/public (set-selection i) (void))
    (define/public (get-selection) 0)
    (define/public (number) 0)
    (define/public (button-focus n) (void))
    (define/public (enable-button i on?) (void))))

(define message%
  (class item%
    (super-new)
    (define/public (get-color) #f)
    (define/public (set-color c) (void))
    (define/public (set-preferred-size) (void))))

(define list-box%
  (class item%
    (super-new)
    (define/public (set-column-order o) (void))
    (define/public (queue-changed) (void))
    (define/public (queue-activated) (void))
    (define/public (column-clicked i) (void))
    (define/public (get-column-order) '())
    (define/public (set-string i s [col 0]) (void))
    (define/public (set-column-label i s) (void))
    (define/public (set-column-size i w mn mx) (void))
    (define/public (get-column-size i) (values 0 0 0))
    (define/public (set-first-visible-item i) (void))
    (define/public (set choices . _) (void))
    (define/public (get-selections) '())
    (define/public (get-selection) -1)
    (define/public (get-first-item) 0)
    (define/public (number-of-visible-items) 0)
    (define/public (number) 0)
    (define/public (set-data i d) (void))
    (define/public (get-data i) #f)
    (define/public (selected? i) #f)
    (define/public (select i [on? #t]) (void))
    (define/public (set-selection i) (void))
    (define/public (delete i) (void))
    (define/public (clear) (void))
    (define/public (append-column s) (void))
    (define/public (delete-column i) (void))))
(define tab-panel%
  (class item%
    (super-new)
    ;; Overridden by the core's wx-make-tab% at load:
    (define/public (on-choice-reorder new-positions) (void))
    (define/public (on-choice-close pos) (void))
    ;; Tab operations (called when tab-panels are actually used):
    (define/public (set-callback cb) (void))
    (define/public (swap-in . _) (void))
    (define/public (page-changed . _) (void))
    (define/public (page-reordered . _) (void))
    (define/public (set choices) (void))
    (define/public (delete i) (void))
    (define/public (number) 0)
    (define/public (button-focus n) (void))
    (define/public (set-selection i) (void))
    (define/public (get-selection) 0)))

;; A dialog is a top-level window: carry the frame% surface.
(define dialog% (class frame% (super-new)))

;; Menus have their own (non-window) protocol. Not functional yet, but they
;; carry the surface the core's wxmenu.rkt inherits/overrides at load.
(define menu%
  (class object%
    (super-new)
    (define/public (get-item) #f)
    (define/public (removing-item i) (void))
    (define/public (do-on-select i) (void))
    (define/public (on-select i) (void))
    (define/public (get-gtk) #f)
    (define/public (set-parent p) (void))
    (define/public (get-top-parent) #f)
    (define/public (set-self-item i) (void))
    (define/public (popup x y queue) (void))
    (define/public (do-selected i) (void))
    (define/public (do-no-selected) (void))
    (define/public (append-separator) (void))
    (define/public (append . _) (void))
    (define/public (select i) (void))
    (define/public (set-help-string i s) (void))
    (define/public (number) 0)
    (define/public (set-label i s) (void))
    (define/public (enable i on?) (void))
    (define/public (check i on?) (void))
    (define/public (checked? i) #f)
    (define/public (delete-by-position p) (void))
    (define/public (delete i) (void))))

(define menu-bar%
  (class object%
    (super-new)
    (define/public (get-top-window) #f)
    (define/public (get-gtk) #f)
    (define/public (set-top-window w) 0)
    (define/public (reset-menu-height h) (void))
    (define/public (get-dialog-level) 0)
    (define/public (set-label-top i s) (void))
    (define/public (enable-top i on?) (void))
    (define/public (delete i pos) (void))
    (define/public (activate-item i) (void))
    (define/public (append . _) (void))))

(define menu-item%
  (class object%
    (super-new)
    (define/public (id) 0)))

;; printer-dc% is wrapped by racket/draw's doc+page-check-mixin at load, which
;; overrides the whole dc<%> drawing API -- so it must be a real dc. Extend
;; backing-dc% (a full dc<%>); printing isn't actually supported yet.
(define printer-dc%
  (class backing-dc%
    (super-new [transparent? #f])
    (define/public (multiple-pages-ok?) #f)))

(define clipboard-driver%
  (class object%
    (init-field [x-selection? #f])
    (super-new)
    (define client #f)
    (define/public (get-client) client)
    (define/public (set-client c orig-types) (set! client c))
    (define/public (get-data type) #f)
    (define/public (get-text-data) #f)
    (define/public (get-bitmap-data) #f)
    (define/public (set-bitmap-data bm timestamp) (void))))

(define cursor-driver%
  (class object%
    (super-new)
    (define/public (set-standard sym) (void))
    (define/public (set-image image hot-x hot-y) (void))
    (define/public (get-handle) #f)
    (define/public (ok?) #t)))

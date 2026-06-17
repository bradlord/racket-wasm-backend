#lang racket/base
;; stubs.rkt -- placeholder platform classes for the wasm backend.
;;
;; The controls and menus are now drawn and functional (control.rkt +
;; controls-extra.rkt + menu.rkt); what remains here are dialogs and the printer
;; dc. The mred core SUBCLASSES the platform classes at module load (wxitem.rkt
;; builds make-control% over item%, etc.) and uses `inherit`, so these can't be
;; bare object% stubs: item% extends window% (and dialog% extends frame%) to
;; expose the required method surface so racket/gui composes/loads. item% is
;; still the base for the platform-values `item%` slot. clipboard-driver% and
;; cursor-driver% ARE constructed (the former at load), so they are real.

(require racket/class
         (only-in "../common/backing-dc.rkt" backing-dc%)
         "window.rkt"
         "frame.rkt")

(provide (protect-out clipboard-driver%
                      cursor-driver%
                      printer-dc%
                      item%
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

;; item% is still the base for the platform-values `item%` slot. The drawn
;; controls (button/check-box/message in control.rkt; choice/gauge/slider/
;; radio-box/list-box/group-panel/tab-panel in controls-extra.rkt) are now real.

;; A dialog is a top-level window: carry the frame% surface.
(define dialog% (class frame% (super-new)))

;; Menus (menu%/menu-bar%/menu-item%) are now real -- see menu.rkt.

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

#lang racket/base
;; stubs.rkt -- placeholder platform classes for the wasm backend.
;;
;; The controls are now drawn and functional (control.rkt + controls-extra.rkt);
;; what remains here are menus, dialogs and the printer dc. The mred core
;; SUBCLASSES the platform classes at module load (wxitem.rkt builds
;; make-control% over item%, etc.) and uses `inherit`, so these can't be bare
;; object% stubs: item% extends window% (and dialog% extends frame%) to expose
;; the required method surface so racket/gui composes/loads. item% is still the
;; base for the platform-values `item%` slot. clipboard-driver% and
;; cursor-driver% ARE constructed (the former at load), so they are real.

(require racket/class
         (only-in "../common/backing-dc.rkt" backing-dc%)
         "window.rkt"
         "frame.rkt")

(provide (protect-out clipboard-driver%
                      cursor-driver%
                      printer-dc%
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

;; item% is still the base for the platform-values `item%` slot. The drawn
;; controls (button/check-box/message in control.rkt; choice/gauge/slider/
;; radio-box/list-box/group-panel/tab-panel in controls-extra.rkt) are now real.

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

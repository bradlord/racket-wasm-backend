#lang racket/base
;; stubs.rkt -- placeholder platform classes for the wasm backend.
;;
;; The first milestone is frame% + canvas% + dc% (canvas-only rendering).
;; Controls, menus, dialogs, and the printer dc are not implemented yet:
;; they only need to EXIST as named classes so platform.rkt can export them
;; and racket/gui can load. Nothing instantiates them unless a program
;; actually creates a button/menu/etc., at which point construction errors
;; with a clear "not yet implemented" message. clipboard-driver% and
;; cursor-driver% ARE constructed (the former at load, via common's
;; the-clipboard), so they get minimal working bodies.

(require racket/class)

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

;; A class that errors when actually instantiated. It declares no inits, so
;; it both compiles and (never being constructed in the milestone) never
;; fires; if a program does create one, instantiation errors -- either on the
;; unexpected by-name init or on the body error below -- which is the intent.
(define-syntax-rule (define-unsupported name)
  (define name
    (class object%
      (super-new)
      (error 'name "not yet implemented in the wasm GUI backend"))))

(define-unsupported button%)
(define-unsupported check-box%)
(define-unsupported choice%)
(define-unsupported gauge%)
(define-unsupported group-panel%)
(define-unsupported list-box%)
(define-unsupported message%)
(define-unsupported radio-box%)
(define-unsupported slider%)
(define-unsupported tab-panel%)
(define-unsupported item%)
(define-unsupported menu%)
(define-unsupported menu-bar%)
(define-unsupported menu-item%)
(define-unsupported dialog%)
(define-unsupported printer-dc%)

;; Minimal clipboard: holds nothing useful yet, but constructs and answers
;; the queries common/clipboard.rkt's clipboard% forwards (it builds one at
;; module load). Browser clipboard access would route through DOM-RPC later.
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

;; Minimal cursor: constructs and accepts standard/image cursors as no-ops.
(define cursor-driver%
  (class object%
    (super-new)
    (define/public (set-standard sym) (void))
    (define/public (set-image image hot-x hot-y) (void))
    (define/public (get-handle) #f)
    (define/public (ok?) #t)))

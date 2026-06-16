#lang racket/base
;; platform.rkt -- the wasm backend's platform-values bundle.
;;
;; PROBE STAGE: the real window/frame/canvas/panel are not written yet, so
;; they are inline error-on-use stubs here alongside the controls in
;; stubs.rkt. This lets racket/gui LOAD under wasm (selected via PLT_WASM_GUI)
;; and verifies the scaffold (procs/stubs/queue/init + the vm-eval foreign
;; procedures) instantiates under the real runtime. Once window/frame/canvas/
;; panel.rkt exist they replace these stubs.

(require racket/class
         "init.rkt"       ; starts the event pump at load
         "procs.rkt"
         "stubs.rkt")

(provide (protect-out platform-values))

;; Inline error-on-use stubs for the not-yet-written core classes.
(define-syntax-rule (define-core-stub name)
  (define name
    (class object%
      (super-new)
      (error 'name "wasm GUI backend: core class not yet implemented"))))
(define-core-stub frame%)
(define-core-stub canvas%)
(define-core-stub canvas-panel%)
(define-core-stub panel%)
(define-core-stub window%)

(define (platform-values)
  (values
   button% canvas% canvas-panel% check-box% choice% clipboard-driver%
   cursor-driver% dialog% frame% gauge% group-panel% item% list-box%
   menu% menu-bar% menu-item% message% panel% printer-dc% radio-box%
   slider% tab-panel% window%
   can-show-print-setup? show-print-setup id-to-menu-item file-selector
   is-color-display? get-display-depth has-x-selection? hide-cursor bell
   display-size display-origin display-count display-bitmap-resolution
   flush-display get-current-mouse-state fill-private-color cancel-quit
   get-control-font-face get-control-font-size get-control-font-size-in-pixels?
   get-double-click-time file-creator-and-type location->window
   shortcut-visible-in-label? unregister-collecting-blit register-collecting-blit
   find-graphical-system-path play-sound get-panel-background
   font-from-user-platform-mode get-font-from-user color-from-user-platform-mode
   get-color-from-user special-option-key special-control-key
   any-control+alt-is-altgr get-highlight-background-color
   get-highlight-text-color get-label-foreground-color get-label-background-color
   make-screen-bitmap make-gl-bitmap check-for-break key-symbol-to-menu-key
   needs-grow-box-spacer? graphical-system-type white-on-black-panel-scheme?
   tab-panel-available?))

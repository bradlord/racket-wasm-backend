#lang racket/base
;; platform.rkt -- the wasm backend's platform-values bundle.
;;
;; Real (thin) window/frame/canvas/panel + dc, plus drawn controls
;; (control.rkt: button%/check-box%/message%; controls-extra.rkt: choice%/
;; gauge%/slider%/radio-box%/list-box%/group-panel%/tab-panel%). Menus, dialogs
;; and the printer dc remain load-bearing stubs (stubs.rkt). Selected via
;; PLT_WASM_GUI in the unix branch of mred/private/wx/platform.rkt.

(require "init.rkt"       ; starts the event pump at load
         "procs.rkt"
         "stubs.rkt"
         "control.rkt"    ; real button%/check-box%/message%
         "controls-extra.rkt" ; choice/gauge/slider/radio-box/list-box/group-panel/tab-panel
         "window.rkt"
         "canvas.rkt"
         "frame.rkt"
         "panel.rkt")

(provide (protect-out platform-values))

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

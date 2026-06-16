#lang racket/base
;; procs.rkt -- system procedures for the wasm backend.
;;
;; Mostly trivial constants/no-ops for the first milestone; several come
;; straight from common/default-procs.rkt. Display geometry is fixed for now
;; (a DOM-RPC query of window.innerWidth/Height is a later refinement), and
;; the font/selection helpers return sane defaults. Anything genuinely
;; unsupported is a no-op rather than an error so racket/gui loads.

(require racket/class
         racket/draw
         "../common/default-procs.rkt")

(provide
 (protect-out
  color-from-user-platform-mode
  get-font-from-user
  font-from-user-platform-mode
  play-sound
  find-graphical-system-path
  register-collecting-blit
  unregister-collecting-blit
  shortcut-visible-in-label?
  get-double-click-time
  get-control-font-face
  get-control-font-size
  get-control-font-size-in-pixels?
  cancel-quit
  bell
  hide-cursor
  get-display-depth
  is-color-display?
  id-to-menu-item
  can-show-print-setup?
  get-highlight-background-color
  get-highlight-text-color
  get-label-background-color
  get-label-foreground-color
  check-for-break
  has-x-selection?
  get-current-mouse-state)
 file-selector
 show-print-setup
 display-origin
 display-size
 display-count
 display-bitmap-resolution
 flush-display
 location->window
 make-screen-bitmap
 make-gl-bitmap
 file-creator-and-type
 special-control-key
 special-option-key
 any-control+alt-is-altgr
 get-panel-background
 fill-private-color
 white-on-black-panel-scheme?
 get-color-from-user
 key-symbol-to-menu-key
 needs-grow-box-spacer?
 graphical-system-type
 tab-panel-available?)

;; --- display geometry (fixed for the first milestone) ---
(define (display-size xb yb [all? #f] [n 0] [fail void])
  (set-box! xb 1024)
  (set-box! yb 768))
(define (display-origin xb yb [all? #f] [n 0] [fail void])
  (set-box! xb 0)
  (set-box! yb 0))
(define (display-count) 1)
(define (display-bitmap-resolution n fail) 1.0)
(define (flush-display) (void))

;; --- fonts / colors ---
(define (get-control-font-face) "Sans")
(define (get-control-font-size) 12)
(define (get-control-font-size-in-pixels?) #f)
(define (get-double-click-time) 250)
(define (get-display-depth) 32)
(define (is-color-display?) #t)
(define (get-highlight-background-color) (make-object color% 180 200 255))
(define (get-highlight-text-color) #f)
(define (get-label-background-color) (make-object color% 220 220 220))
(define (get-label-foreground-color) (make-object color% 0 0 0))
(define (white-on-black-panel-scheme?) #f)
(define (color-from-user-platform-mode) #f)
(define (font-from-user-platform-mode) #f)
(define (get-font-from-user . _) #f)
(define (get-color-from-user . _) #f)

;; --- misc system ---
(define (cancel-quit) (void))
(define (play-sound . _) #f)
(define (bell) (void))
(define (hide-cursor) (void))
(define (check-for-break) #f)
(define (needs-grow-box-spacer?) #f)
(define (graphical-system-type) 'wasm)
(define (tab-panel-available?) #t)
(define (can-show-print-setup?) #t)
(define (show-print-setup . _) (void))
(define (id-to-menu-item i) i)
(define (has-x-selection? . _) #f)
(define (key-symbol-to-menu-key sym) #f)
(define (shortcut-visible-in-label? [mbar? #f]) #t)
(define (find-graphical-system-path what) #f)
(define (location->window x y) #f)

;; Mouse state: (values point-or-#f mods-list). No global pointer poll yet.
(define (get-current-mouse-state)
  (values (make-object point% 0 0) null))

;; Collecting blits (caret/selection flashing) -- delegate to the canvas.
(define (register-collecting-blit canvas x y w h on off on-x on-y off-x off-y)
  (send canvas register-collecting-blit x y w h on off on-x on-y off-x off-y))
(define (unregister-collecting-blit canvas)
  (send canvas unregister-collecting-blits))

;; Off-screen bitmaps are plain Cairo image surfaces.
(define (make-screen-bitmap w h)
  (make-object bitmap% w h #f #t))
(define (make-gl-bitmap w h c)
  (make-object bitmap% w h #f #t))

(define (file-selector . _) #f)

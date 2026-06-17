#lang racket/base
;; menu.rkt -- drawn menus for the wasm backend: menu-bar%, menu%, menu-item%.
;;
;; Menus are not part of the window tree, so they are drawn and routed by the
;; top frame% (see frame.rkt): the frame paints the menu-bar strip across its
;; top and, when a title is clicked, an open menu% as a popup overlay; clicks on
;; an item call back into the menu, which dispatches through the frame's
;; on-menu-command (the same path GTK uses via id-to-menu-item -> wx->mred ->
;; the item's callback). There are no native popups; a submenu opens as a second
;; overlay column beside its parent.
;;
;; Init arg shapes + method surfaces mirror the GTK backend (menu-bar% takes no
;; init args; menu% is (label callback font); menu-item% is empty) since the
;; mred core subclasses and `inherit`s them identically.

(require racket/class
         racket/draw
         "../../lock.rkt"
         "../common/queue.rkt"
         "../common/event.rkt"
         "base.rkt")

(provide (protect-out menu% menu-bar% menu-item%
                      menu-strip-height menu-row-height
                      measure-menu-text menu-font))

;; --- shared measuring dc + metrics ---
(define menu-mdc (new bitmap-dc% [bitmap (make-object bitmap% 1 1)]))
(define menu-font (make-object font% 12 "Sans" 'default 'normal 'normal))
(define (measure-menu-text s)
  (let-values ([(w h d a) (send menu-mdc get-text-extent (if (string? s) s "") menu-font)])
    (values (inexact->exact (ceiling w)) (inexact->exact (ceiling h)))))
(define menu-strip-height 24)
(define menu-row-height 22)

;; menu%/menu-bar% define an `append` method (the mred contract), which shadows
;; racket/base's `append` inside those class bodies -- so use this module-level
;; helper to add to the items/entries lists.
(define (snoc xs x) (append xs (list x)))

;; Strip a single mnemonic '&' and a trailing "\tShortcut".
(define (clean-label s)
  (if (string? s)
      (regexp-replace* #rx"&(.)" (regexp-replace #rx"\t.*$" s "") "\\1")
      ""))
(define (shortcut-of s)
  (if (string? s)
      (let ([m (regexp-match #rx"\t(.*)$" s)]) (if m (cadr m) ""))
      ""))

;; A drawable menu row: a mutable vector
;;   #(kind id label shortcut checkable? checked? enabled? submenu)
;; kind is 'item | 'submenu | 'separator.
(define (row-kind r) (vector-ref r 0))
(define (row-id r) (vector-ref r 1))
(define (row-label r) (vector-ref r 2))
(define (row-shortcut r) (vector-ref r 3))
(define (row-checkable? r) (vector-ref r 4))
(define (row-checked? r) (vector-ref r 5))
(define (row-enabled? r) (vector-ref r 6))
(define (row-submenu r) (vector-ref r 7))

;; ============================================================================

(define menu-item% (class object% (super-new) (define/public (id) this)))

;; ============================================================================

(define menu%
  (class widget%
    (init label callback font)
    (super-new)
    (inherit get-eventspace install-widget-parent)

    (define cb callback)
    (define items '())          ; list of row vectors
    (define parent #f)
    (define self-item #f)
    (define remover void)
    (define ignore-callback? #f)
    (define on-popup #f)

    (define/public (get-gtk) #f)

    (define/public (set-parent p)
      (set! parent p)
      (install-widget-parent p))
    (define/public (get-parent) parent)
    (define/public (get-top-parent)
      (and parent
           (if (is-a? parent menu%)
               (send parent get-top-parent)
               (send parent get-top-window))))

    (define/public (set-self-item i r) (set! self-item i) (set! remover r))
    (define/public (get-item) self-item)
    (define/public (removing-item)
      (set! self-item #f) (remover) (set! remover void))

    ;; --- structure ---
    (define (find r id)
      (cond [(null? r) #f]
            [(eq? (row-id (car r)) id) (car r)]
            [else (find (cdr r) id)]))

    (define/public (append i label help-or-submenu chckable?)
      (define submenu? (is-a? help-or-submenu menu%))
      (define row
        (if submenu?
            (begin
              (send help-or-submenu set-parent this)
              (send help-or-submenu set-self-item i void)
              (vector 'submenu i (clean-label label) "" #f #f #t help-or-submenu))
            (vector 'item i (clean-label label) (shortcut-of label)
                    (and chckable? #t) #f #t #f)))
      (set! items (snoc items row)))

    (define/public (append-separator)
      (set! items (snoc items (vector 'separator #f "" "" #f #f #f #f))))

    (define/public (select bm) (and parent (send parent activate-item this)))
    (define/public (get-font) #f)
    (define/public (set-width w) (void))
    (define/public (set-title s) (void))
    (define/public (set-help-string m s) (void))
    (define/public (number) (length items))

    (define/public (set-label item str)
      (define r (find items item))
      (when r (vector-set! r 2 (clean-label str)) (vector-set! r 3 (shortcut-of str))))
    (define/public (enable item on?)
      (define r (find items item)) (when r (vector-set! r 6 (and on? #t))))
    (define/public (check item on?)
      (define r (find items item)) (when r (vector-set! r 5 (and on? #t))))
    (define/public (checked? item)
      (define r (find items item)) (and r (row-checked? r)))

    (define/public (delete-by-position pos)
      (when (< -1 pos (length items))
        (set! items (for/list ([r (in-list items)] [i (in-naturals)] #:unless (= i pos)) r))))
    (define/public (delete item)
      (set! items (for/list ([r (in-list items)] #:unless (eq? (row-id r) item)) r)))

    ;; --- popup (right-click); handled by the top frame ---
    (define/public (popup x y in-win queue-cb)
      (set! on-popup queue-cb)
      (when in-win
        (define top (send in-win get-top-win))
        (when top (send top open-popup-menu this x y))))

    ;; --- dispatch (called by the frame when a row is chosen) ---
    (define/public (do-selected id)
      (unless ignore-callback?
        (define top (get-top-parent))
        (cond
          [top (queue-event (send top get-eventspace)
                            (lambda () (send top on-menu-command id)))]
          [on-popup
           (let ([e (new popup-event% [event-type 'menu-popdown])] [pu on-popup])
             (set! on-popup #f) (send e set-menu-id id) (pu (lambda () (cb this e))))]
          [parent (send parent do-selected id)])))
    (define/public (do-no-selected) (void))
    (define/public (on-select-item id) (void))

    ;; --- rendering / hit-testing support (used by frame.rkt) ---
    ;; rows for drawing: list of (label shortcut checkable? checked? enabled? submenu?)
    (define/public (get-rows) items)
    (define/public (row-count) (length items))
    ;; The widest label + shortcut, for sizing the popup.
    (define/public (popup-width)
      (for/fold ([m 80]) ([r (in-list items)])
        (define-values (lw lh) (measure-menu-text (row-label r)))
        (define-values (sw sh) (measure-menu-text (row-shortcut r)))
        (max m (+ lw 24 (if (> sw 0) (+ sw 24) 0) 12))))
    ;; Activate row at index: returns 'closed, 'stay (checkable toggled), or a
    ;; submenu menu% to open; #f if nothing happened.
    (define/public (activate-row idx)
      (cond
        [(or (< idx 0) (>= idx (length items))) #f]
        [else
         (define r (list-ref items idx))
         (cond
           [(not (row-enabled? r)) #f]
           [(eq? (row-kind r) 'separator) #f]
           [(eq? (row-kind r) 'submenu) (row-submenu r)]
           [(row-checkable? r)
            (vector-set! r 5 (not (row-checked? r)))
            (do-selected (row-id r))
            'closed]
           [else (do-selected (row-id r)) 'closed])]))))

;; ============================================================================

(define menu-bar%
  (class widget%
    (super-new)
    (inherit install-widget-parent)

    (define entries '())        ; list of (vector title menu enabled?)
    (define top-wx #f)

    (define/public (get-gtk) #f)

    (define/public (set-top-window top)
      (set! top-wx top)
      (install-widget-parent top)
      menu-strip-height)         ; the height the frame reserves for the strip
    (define/public (reset-menu-height [h menu-strip-height]) (void))
    (define/public (get-top-window) top-wx)
    (define/public (get-dialog-level) (if top-wx (send top-wx get-dialog-level) 0))

    (define/public (set-label-top pos str)
      (when (< -1 pos (length entries))
        (vector-set! (list-ref entries pos) 0 (clean-label str))))
    (define/public (enable-top pos on?)
      (when (< -1 pos (length entries))
        (vector-set! (list-ref entries pos) 2 (and on? #t))))
    (define/public (delete which pos)
      (when (< -1 pos (length entries))
        (set! entries (for/list ([e (in-list entries)] [i (in-naturals)] #:unless (= i pos)) e))))

    (define/public (append menu title)
      (send menu set-parent this)
      (set! entries (snoc entries (vector (clean-label title) menu #t))))

    (define/public (activate-item menu) #f)

    ;; --- rendering support (used by frame.rkt) ---
    (define/public (get-entries) entries)   ; list of (vector title menu enabled?)))
    (define/public (count) (length entries))))

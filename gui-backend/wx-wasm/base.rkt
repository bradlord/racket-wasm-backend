#lang racket/base
;; base.rkt -- the wasm backend's widget% base (replaces gtk/widget.rkt).
;;
;; There is no GtkWidget; a "gtk" here is just an opaque logical token a
;; subclass hands up (often #f). We keep only what the mred core needs from
;; widget%: the eventspace, and the gtk->wx hook stubbed (our event pump routes
;; by frame id, not by widget pointer, so the hook is unused).

(require racket/class
         "../common/queue.rkt")

(provide (protect-out widget%
                      gtk->wx))

(define widget%
  (class object%
    (init [gtk #f]
          [extra-gtks null]
          [parent #f])
    (init-field [eventspace (if parent
                                (send parent get-eventspace)
                                (current-eventspace))])
    (when (eventspace-shutdown? eventspace)
      (error '|GUI object initialization| "the eventspace has been shutdown"))
    (super-new)
    (define/public (get-eventspace) eventspace)
    (define/public (direct-update?) #t)
    (define/public (install-widget-parent p)
      (set! eventspace (send p get-eventspace)))
    (define/public (register-extra-gtk gtk extra-gtk) (void))))

;; No widget-pointer registry in the wasm backend.
(define (gtk->wx gtk) #f)

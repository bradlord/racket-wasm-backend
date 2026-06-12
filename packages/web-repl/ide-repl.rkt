#lang racket/base
;; web-repl/ide-repl -- a submission-oriented `current-prompt-read` for
;; the WASM IDE's Interactions REPL.
;;
;; The IDE runs the user's program in a plain console REPL whose stdin is
;; a single shared byte stream that doubles as the program's stdin (see
;; apps/ide/public/ide.js, wasm_shell_io.c). The stock REPL reads ONE datum,
;; then evaluates it -- so if you submit `(foo)(foo)` and `foo` calls
;; `(read-line)`, the first `foo`'s read-line swallows the trailing
;; `(foo)` as its input instead of it being evaluated as an expression.
;;
;; This reader instead consumes a whole *submission* -- one line, or
;; several lines accumulated until the forms balance -- parses ALL of its
;; top-level forms up front, and hands them to the REPL one at a time
;; (via `current-prompt-read`, which `read-eval-print-loop` calls once
;; per form). The submission's bytes are fully drained from stdin before
;; any form runs, so a `read-line` during evaluation blocks for a *fresh*
;; submission rather than eating the rest of the current line. That is
;; exactly DrRacket's separation: the expressions you submit and the
;; input a running program reads are distinct.
;;
;; We override only the *read* step; the stock REPL still evaluates,
;; prints (through the bitmap-aware `current-print`), and handles errors.

(provide install-ide-prompt-read!)

;; Forms parsed from the current submission but not yet handed to the REPL.
(define pending '())

;; Read every top-level form in `text`. Uses `read-syntax` -- for a
;; `#lang racket` REPL that is exactly the interaction reader, and it
;; avoids depending on `current-read-interaction` being installed.
;; Returns one of:
;;   (cons 'ok forms)   -- text parses to a complete list of forms
;;   'incomplete        -- text ends mid-datum; the caller should read more
;;   (cons 'error exn)  -- text has a genuine (non-eof) read error
(define (try-parse text)
  (define in (open-input-string text))
  (port-count-lines! in)
  (with-handlers ([exn:fail:read:eof? (lambda (_) 'incomplete)]
                  [exn:fail:read?     (lambda (e) (cons 'error e))])
    (let loop ([acc '()])
      (define form (read-syntax (object-name in) in))
      (if (eof-object? form)
          (cons 'ok (reverse acc))
          (loop (cons form acc))))))

;; Block reading lines from stdin until the buffered text parses to a
;; complete list of forms; return that list (possibly empty), or eof if
;; the input port closes first. Raises a read error for genuinely
;; malformed input so the REPL's read prompt reports it.
(define (read-submission)
  (define in (current-get-interaction-input-port-value))
  (let loop ([text ""])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line)
       (if (string=? text "") eof (forms-of text))]
      [else
       (define text* (string-append text line "\n"))
       (if (eq? (try-parse text*) 'incomplete)
           (loop text*)
           (forms-of text*))])))

(define (current-get-interaction-input-port-value)
  ((current-get-interaction-input-port)))

(define (forms-of text)
  (define res (try-parse text))
  (cond
    [(and (pair? res) (eq? (car res) 'ok))    (cdr res)]
    [(and (pair? res) (eq? (car res) 'error)) (raise (cdr res))]
    [else '()]))   ; 'incomplete at eof: treat as no forms

(define (ide-prompt-read)
  (cond
    [(pair? pending)
     ;; Drain the rest of the current submission without a new prompt.
     (define form (car pending))
     (set! pending (cdr pending))
     form]
    [else
     (let loop ()
       (display "> ")
       (flush-output)
       (define sub (read-submission))
       (cond
         [(eof-object? sub) eof]
         [(null? sub) (loop)]            ; blank/whitespace submission
         [else
          (set! pending (cdr sub))
          (car sub)]))]))

(define (install-ide-prompt-read!)
  (current-prompt-read ide-prompt-read))

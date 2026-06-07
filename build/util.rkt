#lang racket/base
;; Shared helpers for the orchestrator: subprocess running with streamed output,
;; a thin git wrapper, and small filesystem utilities.
(require racket/string
         racket/port
         racket/file
         racket/path
         racket/system)

(provide run run/string git git/string git/lines
         copy-tree info-msg)

(define (info-msg fmt . args)
  (printf "\033[1;34m==>\033[0m ~a\n" (apply format fmt args))
  (flush-output))

(define (exe name)
  (or (find-executable-path name)
      (error 'run "executable not found on PATH: ~a" name)))

;; Run a command, streaming stdout/stderr to our own. Raises on nonzero exit
;; unless `allow-fail?`. Returns the exit code.
(define (run cmd
             #:args [args '()]
             #:dir [dir #f]
             #:env [env '()]
             #:allow-fail? [allow-fail? #f])
  (define full (cons (path->string (exe cmd)) args))
  (define run-thunk
    (lambda ()
      (define-values (sp out in err)
        (apply subprocess (current-output-port) #f (current-error-port) (exe cmd) args))
      (close-output-port in)
      (subprocess-wait sp)
      (subprocess-status sp)))
  (define code
    (parameterize ([current-directory (or dir (current-directory))])
      (let loop ([pairs env] [thunk run-thunk])
        (if (null? pairs)
            (thunk)
            (loop (cdr pairs)
                  (let ([k (caar pairs)] [v (cdar pairs)] [t thunk])
                    (lambda () (parameterize ([current-environment-variables
                                               (let ([e (environment-variables-copy
                                                         (current-environment-variables))])
                                                 (environment-variables-set! e (string->bytes/utf-8 k)
                                                                             (string->bytes/utf-8 v))
                                                 e)])
                                 (t)))))))))
  (unless (or allow-fail? (zero? code))
    (error 'run "command failed (exit ~a): ~a" code (string-join full " ")))
  code)

;; Capture stdout of a command as a string (stderr passes through).
(define (run/string cmd #:args [args '()] #:dir [dir #f])
  (define-values (sp out in err)
    (parameterize ([current-directory (or dir (current-directory))])
      (apply subprocess #f #f (current-error-port) (exe cmd) args)))
  (close-output-port in)
  (define s (port->string out))
  (subprocess-wait sp)
  (close-input-port out)
  (define code (subprocess-status sp))
  (unless (zero? code)
    (error 'run/string "command failed (exit ~a): ~a ~a" code cmd (string-join args " ")))
  s)

;; git in a given working tree.
(define (git dir . args)
  (run "git" #:dir dir #:args args))
(define (git/string dir . args)
  (run/string "git" #:dir dir #:args args))
(define (git/lines dir . args)
  (filter (lambda (s) (not (string=? s "")))
          (string-split (apply git/string dir args) "\n")))

;; Recursively copy the *contents* of src into dst (merging into existing dirs),
;; overwriting files. Both are directories.
(define (copy-tree src dst)
  (make-directory* dst)
  (for ([p (in-list (directory-list src))])
    (define s (build-path src p))
    (define d (build-path dst p))
    (cond
      [(directory-exists? s) (copy-tree s d)]
      [else
       (make-directory* (path-only d))
       (when (or (file-exists? d) (link-exists? d)) (delete-file d))
       (copy-file s d)])))

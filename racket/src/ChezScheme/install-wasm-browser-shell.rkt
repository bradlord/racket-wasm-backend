#lang racket/base

(require racket/cmdline
         racket/file
         racket/path)

(define script-path (path->complete-path (find-system-path 'run-file)))
(define chez-dir (simplify-path (path-only script-path)))
(define shell-dir (build-path chez-dir "wasm-shell"))

(define target-dir
  (command-line
   #:program "install-wasm-browser-shell.rkt"
   #:args [target-dir]
   (path->complete-path target-dir)))

(define files
  '("browser-shell.html"
    "browser-shell.js"))

(make-directory* target-dir)

(for ([name (in-list files)])
  (copy-file (build-path shell-dir name)
             (build-path target-dir name)
             #t))

(printf "installed browser shell assets into ~a\n" target-dir)
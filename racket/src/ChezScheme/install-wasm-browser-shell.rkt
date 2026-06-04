#lang racket/base

(require racket/cmdline
         racket/file
         racket/path)

(define script-path (path->complete-path (find-system-path 'run-file)))
(define chez-dir (simplify-path (path-only script-path)))
;; wasm-shell now lives at the repo root (chez-dir is repo/racket/src/ChezScheme).
(define repo-dir (simplify-path (build-path chez-dir 'up 'up 'up)))
(define shell-dir (build-path repo-dir "wasm-shell"))

(define target-dir
  (command-line
   #:program "install-wasm-browser-shell.rkt"
   #:args [target-dir]
   (path->complete-path target-dir)))

;; Runtime assets copied next to the generated scheme-web.* files.
;; (shell-tty.js is NOT here: it is a build-time `emcc --post-js` input,
;; already baked into scheme-web.js, not a separately served file.)
(define files
  '("browser-shell.html"
    "browser-shell.js"
    "playground.html"
    "playground.js"
    "shell-worker.js"
    "serve.rkt"))

(make-directory* target-dir)

(for ([name (in-list files)])
  (copy-file (build-path shell-dir name)
             (build-path target-dir name)
             #t))

(printf "installed browser shell assets into ~a\n" target-dir)

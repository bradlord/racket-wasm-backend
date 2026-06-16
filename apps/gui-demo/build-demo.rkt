#lang racket/base
;; Post-build hook for the gui-demo app (wired in via app.rkt's `hooks` field).
;;
;; The demo's racket/gui program lives in its own file (`demo.rkt`) so it reads
;; and edits like normal Racket, and the page driver source lives at
;; `gui-demo.js` (next to this module, *outside* `public/` so collect-outputs
;; doesn't copy it verbatim). This hook runs once dist/ is assembled: it reads
;; `demo.rkt`, JSON-encodes its full text into a JS string literal, splices it
;; into `gui-demo.js` in place of the `__PROGRAM__` token, and writes the result
;; to `dist/gui-demo.js` (which index.html loads).
;;
;; Mirrors apps/ide/build-examples.rkt (the IDE's ide.js generator).
(require racket/file
         racket/string
         json)

(provide build-demo-js)

(define (build-demo-js ctx)
  (define app-dir (hash-ref ctx 'app-dir))
  (define dist    (hash-ref ctx 'dist))
  (define program-src (build-path app-dir "demo.rkt"))
  (define template    (build-path app-dir "gui-demo.js"))
  (unless (file-exists? program-src)
    (error 'build-demo-js "no demo source at ~a" program-src))
  (unless (file-exists? template)
    (error 'build-demo-js "no gui-demo.js template at ~a" template))
  (define program (file->string program-src))
  (define tmpl (file->string template))
  (define n-tokens (length (regexp-match-positions* #rx"__PROGRAM__" tmpl)))
  (unless (= n-tokens 1)
    (error 'build-demo-js "expected exactly one __PROGRAM__ token in ~a, found ~a"
           template n-tokens))
  ;; jsexpr->string of a string yields a valid JS string literal.
  (define out (string-replace tmpl "__PROGRAM__" (jsexpr->string program)))
  (define dest (build-path dist "gui-demo.js"))
  (call-with-output-file dest #:exists 'replace
    (lambda (o) (write-string out o)))
  (printf "gui-demo.js: spliced demo.rkt (~a bytes) into ~a\n"
          (string-length program) dest))

#lang racket/base
;; Post-build hook: splice drracket-main.rkt into drracket.js -> dist/drracket.js
(require racket/file racket/string json)
(provide build-drracket-js)

(define (build-drracket-js ctx)
  (define app-dir (hash-ref ctx 'app-dir))
  (define dist    (hash-ref ctx 'dist))
  (define program-src (build-path app-dir "drracket-main.rkt"))
  (define template    (build-path app-dir "drracket.js"))
  (unless (file-exists? program-src)
    (error 'build-drracket-js "no source at ~a" program-src))
  (unless (file-exists? template)
    (error 'build-drracket-js "no drracket.js template at ~a" template))
  (define program (file->string program-src))
  (define tmpl (file->string template))
  (define n-tokens (length (regexp-match-positions* #rx"__PROGRAM__" tmpl)))
  (unless (= n-tokens 1)
    (error 'build-drracket-js "expected exactly one __PROGRAM__ token, found ~a" n-tokens))
  (define out (string-replace tmpl "__PROGRAM__" (jsexpr->string program)))
  (define dest (build-path dist "drracket.js"))
  (call-with-output-file dest #:exists 'replace
    (lambda (o) (write-string out o)))
  (printf "drracket.js: spliced drracket-main.rkt (~a bytes) into ~a\n"
          (string-length program) dest))

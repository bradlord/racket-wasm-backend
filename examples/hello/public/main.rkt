#lang racket/base
;; The hello app's program. The page seeds this at /tmp/main.rkt in MEMFS and
;; runs the runtime with argv ["-u" "/tmp/main.rkt"] (run a module, then exit).
;; Everything it prints to stdout is drained from the output ring by hello.js
;; and shown on the page. Core only -- no racket/draw, no web-repl.
(printf "Hello from Racket, compiled to WebAssembly.\n")
(printf "2 + 2 = ~a\n" (+ 2 2))
(printf "(string-upcase \"racket\") = ~a\n" (string-upcase "racket"))
(for ([i (in-range 1 9)])
  (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
  (printf "fib(~a) = ~a\n" i (fib i)))

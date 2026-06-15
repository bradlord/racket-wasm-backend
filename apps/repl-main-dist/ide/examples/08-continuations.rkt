#lang racket

;; First-class continuations work in the WASM build -- both the
;; escaping kind (call/cc) and the delimited kind that racket/generator
;; is built on.

;; --- call/cc as an early escape from a loop ---
(define (first-even lst)
  (call/cc
   (lambda (return)
     (for ([x (in-list lst)])
       (when (even? x) (return x)))
     #f)))

(printf "first even of '(1 3 5 8 9 10): ~a~n"
        (first-even '(1 3 5 8 9 10)))

;; --- a resumable generator (delimited continuations) ---
(require racket/generator)

;; Yields the Fibonacci numbers one at a time; each (fib) resumes the
;; captured continuation where the last yield left off.
(define fib
  (generator ()
    (let loop ([a 0] [b 1])
      (yield a)
      (loop b (+ a b)))))

(printf "first 10 Fibonacci numbers: ~a~n"
        (for/list ([_ (in-range 10)]) (fib)))

;; After Run, call (fib) at the REPL -- it picks up right where the
;; sequence left off.

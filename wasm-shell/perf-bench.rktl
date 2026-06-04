;; Single-threaded, CPU-bound microbenchmark shared by the native and
;; WASM Racket CS runtimes.  Timed internally with current-process-
;; milliseconds so the WASM runtime's (large) startup cost is excluded;
;; this measures steady-state compute only.  Fed to either runtime via
;; stdin.  Each result line is prefixed BENCH so it survives the REPL
;; prompt noise on the WASM surface.

(define (bench name iters thunk)
  (collect-garbage)
  (let ([t0 (current-process-milliseconds)]
        [r0 (current-inexact-milliseconds)])
    (let loop ([i iters] [v #f])
      (if (= i 0)
          (let ([cpu (- (current-process-milliseconds) t0)]
                [real (- (current-inexact-milliseconds) r0)])
            (printf "BENCH ~a\tcpu=~ams\treal=~ams\titers=~a\tresult=~a\n"
                    name cpu (inexact->exact (round real)) iters v))
          (loop (- i 1) (thunk))))))

;; --- recursive integer calls -----------------------------------------
(define (fib n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(define (tak x y z)
  (if (not (< y x))
      z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))

(define (ack m n)
  (cond [(= m 0) (+ n 1)]
        [(= n 0) (ack (- m 1) 1)]
        [else (ack (- m 1) (ack m (- n 1)))]))

;; --- tight fixnum loop -----------------------------------------------
(define (sum-loop n)
  (let loop ([i 0] [acc 0])
    (if (= i n) acc (loop (+ i 1) (+ acc i)))))

;; --- flonum work -----------------------------------------------------
(define (fsum n)
  (let loop ([i 0] [acc 0.0])
    (if (= i n)
        acc
        (loop (+ i 1)
              (+ acc (/ 1.0 (+ 1.0 (exact->inexact i))))))))

;; --- vector / memory: sieve of Eratosthenes -------------------------
(define (sieve n)
  (let ([v (make-vector n #t)])
    (let loop ([i 2] [count 0])
      (if (>= i n)
          count
          (if (vector-ref v i)
              (begin
                (let mark ([j (* i i)])
                  (when (< j n)
                    (vector-set! v j #f)
                    (mark (+ j i))))
                (loop (+ i 1) (+ count 1)))
              (loop (+ i 1) count))))))

;; --- list allocation + sort -----------------------------------------
(define (list-sort-bench n)
  (let ([xs (let loop ([i 0] [acc '()])
              (if (= i n)
                  acc
                  (loop (+ i 1) (cons (modulo (* i 2654435761) n) acc))))])
    (length (sort xs <))))

;; --- string building -------------------------------------------------
(define (string-bench n)
  (let ([o (open-output-string)])
    (let loop ([i 0])
      (when (< i n)
        (write-string (number->string i) o)
        (loop (+ i 1))))
    (string-length (get-output-string o))))

(printf "BENCH == start ==\n")
(bench 'fib33        10 (lambda () (fib 33)))
(bench 'tak.24.16.8  20 (lambda () (tak 24 16 8)))
(bench 'ack.3.9      10 (lambda () (ack 3 9)))
(bench 'sum-loop-50M  5 (lambda () (sum-loop 50000000)))
(bench 'fsum-20M      5 (lambda () (fsum 20000000)))
(bench 'sieve-10M     5 (lambda () (sieve 10000000)))
(bench 'list-sort-1M  5 (lambda () (list-sort-bench 1000000)))
(bench 'string-1M     5 (lambda () (string-bench 1000000)))
(printf "BENCH == done ==\n")

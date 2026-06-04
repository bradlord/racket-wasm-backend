#lang racket/base
;; http-get -- synchronous HTTP GET from the runtime worker via a
;; blocking XHR on the page side (racket/src/cs/c/wasm_http.c). Returns
;; two values: the HTTP status (integer) and the response body (bytes).
;;
;;   (define-values (status body) (http-get "https://api.github.com/zen"))
;;
;; The reply is written status-int32-then-body into a fixed buffer;
;; #:capacity bounds it. A body larger than the buffer is reported as
;; an error carrying the needed size.

(require ffi/unsafe/vm)

(provide http-get)

(define wasm-http-get-raw
  (vm-eval '(foreign-procedure "wasm_http_get" (string u8* int) int)))

(define (http-get url #:capacity [cap (* 1024 1024)])
  (define buf (make-bytes cap))
  (define n (wasm-http-get-raw url buf (bytes-length buf)))
  (cond
    [(= n -1) (error 'http-get "transport error (not in the browser shell?)")]
    [(negative? n) (error 'http-get "response too large (~a bytes); raise #:capacity" (- n))]
    [else (values (integer-bytes->integer buf #f #f 0 4)   ; HTTP status
                  (subbytes buf 4 n))]))                    ; body

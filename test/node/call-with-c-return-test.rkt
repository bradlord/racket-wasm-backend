;; Minimal repro for the `call-with-c-return` signature-mismatch trap on WASM.
;;
;; `#:callback-exns? #t` routes the ffi-call through the exns?-guarded path
;; (foreign.ss:1687) -> call-guarding-foreign-escape (foreign.ss:1931) ->
;; call-with-c-return (foreign.ss:1956 -> compiled chunk_15941). On tpb32l the
;; trampoline's call_indirect uses the fixnum-encoded table slot (T*4) instead
;; of T, so it traps with `function signature mismatch`.
;;
;; Run (no rebuild needed -- uses the existing clone runtime):
;;   tail -n +2 test/node/call-with-c-return-test.rkt \
;;     | node .work/racket/racket/src/build/cs/c/wasm/racket.js
;;
;; (tail -n +2 strips the #lang line; the REPL reads top-level forms.)

#lang racket

(require ffi/unsafe)

(printf "machine-type = ~a~n" (system-type 'machine))

;; --- Control: same call WITHOUT the guarded path. Should NOT trap. ---------
(define abs-plain (get-ffi-obj "abs" #f (_fun _int -> _int)))
(printf "control abs(-5) [no callback-exns] = ~a~n" (abs-plain -5))

;; --- Variant A: int -> int through the guarded path ------------------------
(define abs-guarded (get-ffi-obj "abs" #f (_fun #:callback-exns? #t _int -> _int)))
(printf "BEFORE guarded abs (int->int)~n")
(printf "guarded abs(-5) = ~a~n" (abs-guarded -5))
(printf "AFTER guarded abs (no trap)~n")

;; --- Variant B: different outer signature (double -> double) ---------------
;; If this traps identically to Variant A, the bug is independent of the outer
;; function signature (confirming the trampoline-internal root cause).
(define floor-guarded (get-ffi-obj "floor" #f (_fun #:callback-exns? #t _double -> _double)))
(printf "BEFORE guarded floor (double->double)~n")
(printf "guarded floor(3.7) = ~a~n" (floor-guarded 3.7))
(printf "AFTER guarded floor (no trap)~n")

(printf "ALL DONE~n")

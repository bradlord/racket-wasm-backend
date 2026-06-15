#lang racket

;; Welcome to the Racket WASM IDE. Edit a program here, then press
;; Run (or Cmd/Ctrl+Enter). The Interactions pane on the right runs
;; these definitions and drops into a REPL in their namespace -- so
;; every top-level definition below is in scope there, just like
;; DrRacket.

(displayln "Hello, world!")

(define (greet who)
  (printf "Hello, ~a!\n" who))

(greet "Racket on WASM")

;; After Run, try typing (greet "you") at the REPL on the right.

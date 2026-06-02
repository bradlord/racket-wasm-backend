#lang racket

(begin (require setup/cross-system)
  (unless (= (vector-length (current-command-line-arguments)) 1)
    (error "Expected target machine not given."))
  (define expected-target-machine (vector-ref (current-command-line-arguments) 0))
  (unless (cross-installation?)
    (error "Not in cross installation mode"))
  (define target-machine (symbol->string (cross-system-type (quote target-machine))))
  (unless (string=? target-machine expected-target-machine)
    (error (format "Unexpected target machine: ~s (expected ~s)"
                   target-machine expected-target-machine)))
  (displayln (format "In cross installation mode for target machine: ~a" target-machine)))

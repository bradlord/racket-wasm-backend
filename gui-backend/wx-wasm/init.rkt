#lang racket/base
;; init.rkt -- start the wasm backend event pump at load (required by
;; platform.rkt, mirroring gtk/init.rkt and cocoa/init.rkt).
(require "queue.rkt")

(define pump-thread (wasm-start-event-pump))

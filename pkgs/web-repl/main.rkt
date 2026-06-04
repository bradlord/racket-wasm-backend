#lang racket/base
;; web-repl -- one require for every WASM browser-surface helper. Pull
;; in a single piece instead (web-repl/display-bm, web-repl/canvas,
;; web-repl/dom, web-repl/http) if you don't want the whole set.

(require "canvas.rkt"
         "display-bm.rkt"
         "dom.rkt"
         "http.rkt")

(provide (all-from-out "canvas.rkt"
                       "display-bm.rkt"
                       "dom.rkt"
                       "http.rkt"))

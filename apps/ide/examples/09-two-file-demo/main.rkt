#lang racket
;; Pull the shape helpers in from shapes.rkt; frame/inset are pict's.
(require pict "shapes.rkt")

(frame (inset (labeled-row) 20))

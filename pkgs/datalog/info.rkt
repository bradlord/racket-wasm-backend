#lang info

(define collection "datalog")

;; WASM vendor note (TEMPORARY -- revisit): this is a hand-trimmed copy of
;; the upstream `datalog` package (github.com/racket/datalog). The
;; `scribblings` and `build-deps` (racket-doc, scribble-lib, rackunit-lib)
;; were dropped so the wasm build only pulls the runtime deps below. The
;; `tests/` directory and the `(module+ test ...)` blocks under `tool/`
;; were removed for the same reason. See build-wasm.md "Trimming doc-only
;; build-deps". Keep `deps` in sync with upstream if you re-vendor.
;;
;; This vendored fork is a stopgap, not the desired end state: it pins a
;; stale copy we must hand-sync with upstream. The real fix belongs
;; upstream/in the install flow -- e.g. installing with build-deps excluded
;; (no `raco pkg install` knob exists today) or persuading upstream to split
;; out a doc-free `datalog-lib`. Remove this directory once either lands.

(define deps '("base"
               "parser-tools-lib"
               "syntax-color-lib"))

(define pkg-desc "An implementation of the Datalog language (wasm-trimmed)")

(define pkg-authors '(jay))

(define license
  '(Apache-2.0 OR MIT))

#lang info
;; web-repl as a *package* (not a core-collects collection). This is the
;; racket-wasm repo's deliberate divergence from the fork, which ships web-repl
;; under racket/collects: print.rkt statically requires pict, but the first
;; cross `raco setup` compiles core collects *before* packages are installed, so
;; an in-collects web-repl can't resolve pict and a clean (binary-catalog)
;; rebuild fails. As a package depending on pict-lib, web-repl is absent from
;; that first setup and is compiled afterwards in dependency order (pict first).
;; Installed into share/pkgs, it is preloaded by the wasm link like any other
;; package. See build-wasm.md "web-repl" / "Binary-only package preload".
(define collection "web-repl")
(define version "1.0")
(define deps '("base" "draw-lib" "pict-lib" "net-lib"))
(define pkg-desc "WASM browser-surface REPL helpers (canvas/dom/http/pict printing)")
;; pkg/dirs-catalog requires authors when cataloging ./pkgs.
(define pkg-authors '("brad@bradleylord.com"))

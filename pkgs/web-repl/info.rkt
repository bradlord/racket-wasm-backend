#lang info

;; web-repl -- helpers for the Racket-on-WASM browser surfaces (the
;; REPL and the playground). Wraps the WASM-only C primitives
;; (racket/src/cs/c/wasm_{canvas,dom,http}.c) that are registered with
;; Sforeign_symbol but unreachable through ffi-lib/get-ffi-obj under
;; Emscripten (no dlopen). See build-wasm.md, "Calling WASM-specific
;; primitives from Racket".
;;
;; Installed into the WASM image via the build's PKGS mechanism: add
;; `web-repl` to PKGS (alongside draw-lib) so the in-tree install copies
;; it into racket/share/pkgs and lists it in links.rktd, which the wasm
;; link preloads wholesale.

(define collection "web-repl")

;; Only `base`: every primitive is reached via ffi/unsafe/vm, and the
;; one bitmap helper takes a bitmap% by argument (the caller requires
;; racket/draw), so the package itself doesn't depend on draw-lib.
(define deps '("base"))

(define pkg-desc
  "WASM browser-surface helpers (canvas blit, DOM RPC, HTTP) for the Racket REPL/playground")

(define pkg-authors '(bradlord))

(define license '(Apache-2.0 OR MIT))

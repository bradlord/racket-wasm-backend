#lang racket/base
;; App manifest for DrRacket on WASM.
;;
;; `drracket` is the top-level package; raco pkg install resolves its full
;; transitive closure (framework, typed-racket-lib, drracket-core-lib, etc.).
;; The first build is slow (typed-racket-lib alone takes ~20 min to cross-
;; compile) but subsequent builds reuse the cached catalog.
;;
;; The startup program (drracket-main.rkt) just requires drracket-normal,
;; which runs the normal startup sequence: splash -> tool-lib -> DrRacket frame.
;; PLT_WASM_GUI is set via argv (same as gui-demo) so wx/wasm is selected before
;; racket/gui/base loads.
(provide app)

(require "build-drracket.rkt")

(define app
  (hash
   'pkgs       '(drracket)
   'wasm-libs  '(draw)
   'public     "public"
   'hooks      (hash 'post-build build-drracket-js)))

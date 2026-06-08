#lang racket/base
;; App manifest for the DrRacket-like IDE / web-repl surface -- the repo's
;; canonical app, and the dogfood of `make-wasm-racket` (build/app.rkt): the
;; default `racket build/main.rkt build` builds *this* app into dist/, through
;; the same generic path any custom app uses. There is no bespoke IDE build.
;;
;; The IDE needs the racket/draw stack (bitmaps render in the page) and the
;; web-repl helper package (display-bm / dom / http / the submission REPL reader
;; and bitmap printer the page injects as a prelude).
(provide app)

(define app
  (hash
   ;; Catalog packages (by name).
   'pkgs       '(draw-lib datalog pict-lib)
   ;; Native C deps: the full cairo/pango stack racket/draw needs.
   'wasm-libs  '(draw)
   ;; The web-repl helper package, by path (--copy-installed). Relative to this
   ;; app dir -> the repo's packages/web-repl. The clone stays pure upstream.
   'local-pkgs '("../../packages/web-repl")
   ;; The page surface: ide.html + ide.js.
   'public     "public"))

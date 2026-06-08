#lang racket/base
;; App manifest for the `hello` example -- the smallest possible custom
;; Racket/WASM web app: its own page surface (public/) that runs a core-only
;; Racket program against the shared runtime. Build it with:
;;
;;   racket build/main.rkt app examples/hello \
;;     --scheme <host-chez> --racket <host-racket>
;;
;; Output lands in examples/hello/dist (override with --dest). Serve that dir
;; with COOP/COEP headers and open hello.html:
;;
;;   cd examples/hello/dist && racket serve.rkt 8123   # -> /hello.html
;;
;; The manifest is a real Racket module that `(provide app)` a hash of fields
;; (see build/app.rkt `make-wasm-racket`); it is free to compute them.
(provide app)

(define app
  (hash
   ;; Core distribution only -- no extra packages, no native draw stack. The
   ;; program prints text; that is all the runtime needs.
   'pkgs      '()
   'wasm-libs '()
   ;; The page surface (html/js/racket) lives here, resolved relative to this
   ;; app dir. Every file in it is copied next to the runtime in the output.
   'public    "public"))

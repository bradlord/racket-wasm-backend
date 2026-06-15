#lang racket/base
;; App manifest for the `hello` example -- the smallest possible custom
;; Racket/WASM web app: its own page surface (public/) that runs a core-only
;; Racket program against the shared runtime. Build it with:
;;
;;   racket build/main.rkt app examples/hello \
;;     --scheme <host-chez> --racket <host-racket>
;;
;; Output lands in examples/hello/dist (override with --dest). Serve that dir
;; with COOP/COEP headers (serve.rkt is repo-side glue, run it in place) and
;; open / (the page is index.html):
;;
;;   racket build/main.rkt serve examples/hello/dist 8123
;;   # or: cd examples/hello/dist && racket ../../../runtime-glue/serve.rkt 8123
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
   'public    "public"
   ;; Which runtime surface to ship: 'browser (default) emits racket-web.* +
   ;; share.data* + the worker glue; 'node emits racket.* only. Omit for browser.
   'target    'browser))

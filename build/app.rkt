#lang racket/base
;; The app-assembly API: build a *custom* Racket/WASM web app -- the runtime
;; binaries + glue plus the app's own page surface -- into an arbitrary output
;; dir, instead of the built-in IDE. This is the scriptable entry point the
;; project goal calls for: point at a directory of HTML/JS/Racket + a config and
;; get a runnable web page out.
;;
;;   (make-wasm-racket #:dest "out"
;;                     #:pkgs '(draw-lib)
;;                     #:wasm-libs '(draw)
;;                     #:public "app/public")
;;
;; It wraps stages.rkt's `build-runtime` (the same engine the CLI `build` uses),
;; differing only in the output `dest` and the page `surface-dir`. The runtime
;; binary is surface-agnostic, so any app rides the same scheme-web.*.
;;
;; An app is described by a manifest module (`app.rkt` in the app dir) that
;; `(provide app)` a hash of the keyword fields below; `run-app-manifest` loads
;; it and calls `make-wasm-racket`. "Configuration written in Racket": the
;; manifest is a real module, free to compute its fields.
(require racket/string
         racket/path
         "config.rkt"
         "stages.rkt")

(provide make-wasm-racket run-app-manifest)

;; A list of symbols/strings -> the space-joined make-var string make-wasm wants.
;; '() / "" means "none" (libffi-only for wasm-libs; no extra packages).
(define (->names xs)
  (cond
    [(string? xs) xs]
    [(list? xs)
     (string-join
      (for/list ([x (in-list xs)])
        (if (symbol? x) (symbol->string x) (format "~a" x)))
      " ")]
    [(symbol? xs) (symbol->string xs)]
    [else (format "~a" xs)]))

(define (->path p)
  (cond [(path? p) p]
        [(string? p) (string->path p)]
        [else (error 'make-wasm-racket "expected a path or string, got: ~s" p)]))

;; Build an app into `dest`.
;;   #:pkgs       packages to install (symbols or strings); '() = core only.
;;   #:wasm-libs  native C dep selection ("draw" alias, or '()); libffi always.
;;   #:public     the app's page surface dir (html/js/css/assets) -> dist surface.
;;   #:local-pkgs app-local package source dirs (paths). Installed into share/pkgs
;;                via `raco pkg install --copy`, so app code can live anywhere --
;;                the clone stays pure upstream-delta. Their contents feed the
;;                build-key, so editing one rebuilds.
;;   #:scheme / #:racket  host toolchain paths, or #f to resolve/build.
(define (make-wasm-racket #:dest dest
                          #:pkgs [pkgs '()]
                          #:wasm-libs [wasm-libs '()]
                          #:public [public #f]
                          #:local-pkgs [local-pkgs '()]
                          #:scheme [scheme #f]
                          #:racket [racket #f]
                          #:force? [force? #f])
  (build-runtime #:pkgs       (->names pkgs)
                 #:wasm-deps   (->names wasm-libs)
                 #:local-pkgs  (map (lambda (p) (path->complete-path (->path p))) local-pkgs)
                 #:scheme      scheme
                 #:racket      racket
                 #:dest        (->path dest)
                 #:surface-dir (and public (->path public))
                 #:force?      force?))

;; Load an app manifest module (`<app-dir>/app.rkt` providing `app`, a hash of
;; the make-wasm-racket fields) and build it. `dest` defaults to <app-dir>/dist;
;; the manifest's `public` is resolved relative to the app dir. scheme/racket
;; pass through from the CLI.
(define (run-app-manifest app-dir
                          #:dest [dest #f]
                          #:scheme [scheme #f]
                          #:racket [racket #f]
                          #:force? [force? #f])
  (define dir (->path app-dir))
  (unless (directory-exists? dir)
    (error 'app "no app directory at ~a" dir))
  (define manifest (build-path dir "app.rkt"))
  (unless (file-exists? manifest)
    (error 'app "app manifest not found: ~a (expected an app.rkt providing `app`)" manifest))
  (define spec (dynamic-require manifest 'app))
  (unless (hash? spec)
    (error 'app "~a must provide `app` as a hash of fields, got: ~s" manifest spec))
  (define (ref k [d '()]) (hash-ref spec k d))
  (define public (ref 'public #f))
  (make-wasm-racket
   #:dest       (or dest (build-path dir "dist"))
   #:pkgs       (ref 'pkgs '())
   #:wasm-libs  (ref 'wasm-libs '())
   ;; Resolve local-package + surface paths relative to the app dir.
   #:local-pkgs (for/list ([p (in-list (ref 'local-pkgs '()))])
                  (path->complete-path (->path p) dir))
   #:public     (and public (path->complete-path (->path public) dir))
   #:scheme     scheme
   #:racket     racket
   #:force?     force?))

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
;; binary is surface-agnostic, so any app rides the same racket-web.*.
;;
;; An app is described by a manifest module (`app.rkt` in the app dir) that
;; `(provide app)` a hash of the keyword fields below; `run-app-manifest` loads
;; it and calls `make-wasm-racket`. "Configuration written in Racket": the
;; manifest is a real module, free to compute its fields.
(require racket/string
         racket/path
         "config.rkt"
         "stages.rkt")

(provide make-wasm-racket run-app-manifest package-app-manifest
         cross-sdk-app-manifest read-app-manifest)

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
;;   #:target     'browser (default) or 'node -- which surface to ship into dist:
;;                browser = racket-web.* + share.data* + glue; node = racket.*.
;;   #:pre-js / #:post-js / #:extern-pre-js  app-supplied emcc link JS (lists of
;;                paths) spliced into the #:target surface's link only. They feed
;;                the build-key (editing one relinks), and the targeted surface
;;                keys separately from the other once present.
(define (make-wasm-racket #:dest dest
                          #:pkgs [pkgs '()]
                          #:wasm-libs [wasm-libs '()]
                          #:public [public #f]
                          #:local-pkgs [local-pkgs '()]
                          #:target [target 'browser]
                          #:pre-js [pre-js '()]
                          #:post-js [post-js '()]
                          #:extern-pre-js [extern-pre-js '()]
                          #:scheme [scheme #f]
                          #:racket [racket #f]
                          #:runtime-pkg [runtime-pkg #f]
                          #:force? [force? #f]
                          #:emcc-flags [emcc-flags ""])
  (define (->paths xs) (map (lambda (p) (path->complete-path (->path p))) xs))
  (build-runtime #:pkgs          (->names pkgs)
                 #:wasm-deps      (->names wasm-libs)
                 #:local-pkgs     (->paths local-pkgs)
                 #:pre-js         (->paths pre-js)
                 #:post-js        (->paths post-js)
                 #:extern-pre-js  (->paths extern-pre-js)
                 #:scheme         scheme
                 #:racket         racket
                 #:dest           (->path dest)
                 #:surface-dir    (and public (->path public))
                 #:target         (normalize-target target)
                 #:runtime-pkg    (and runtime-pkg (->path runtime-pkg))
                 #:force?         force?
                 #:emcc-flags     emcc-flags))

;; Load an app manifest module (`<app-dir>/app.rkt` providing `app`, a hash of
;; the make-wasm-racket fields) and return its fields normalized & resolved
;; against the app dir: 'pkgs / 'wasm-libs (symbol/string lists as-is),
;; 'local-pkgs (absolute paths), 'public (absolute path or #f), 'target
;; ('browser/'node, default browser), 'pre-js / 'post-js / 'extern-pre-js
;; (absolute paths to app-supplied emcc link JS), 'hooks (a hash of build-hook
;; procedures, see below), 'dir. This is
;; the single source of truth for an app's build config (used by
;; `run-app-manifest`), so the IDE's package/dep set lives in one place:
;; apps/ide/app.rkt.
(define (read-app-manifest app-dir)
  ;; Absolute + simplified, so it works as a base for app-relative paths whether
  ;; the caller passed an absolute (ide-app-dir) or relative (CLI `app <dir>`) one.
  (define dir (simplify-path (path->complete-path (->path app-dir))))
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
  ;; Resolve app-relative paths to absolute *simplified* form (collapse `..`),
  ;; so e.g. apps/ide/../../packages/web-repl == the repo's packages/web-repl --
  ;; matters because the local-package path feeds the build-key.
  (define (resolve p) (simplify-path (path->complete-path (->path p) dir)))
  ;; A link-JS field is a list of app-relative .js paths (a bare string is
  ;; accepted as a one-element list, like 'public); resolve each.
  (define (resolve-list k)
    (define v (ref k '()))
    (map resolve (if (or (string? v) (path? v)) (list v) v)))
  ;; Optional build hooks: a hash mapping a hook-name symbol to a procedure the
  ;; build calls at that point. Currently the only point is 'post-build, called
  ;; once dist/ is fully assembled with a context hash (see `run-app-manifest`),
  ;; e.g. to generate extra files into dist/. The hash is named generically so
  ;; more hook points can be added without reshaping the manifest.
  (define hooks (ref 'hooks (hash)))
  (unless (hash? hooks)
    (error 'app "~a: `hooks` must be a hash of hook-name -> procedure, got: ~s" manifest hooks))
  (for ([(k v) (in-hash hooks)])
    (unless (procedure? v)
      (error 'app "~a: hook `~a` must be a procedure, got: ~s" manifest k v)))
  (hash 'dir           dir
        'pkgs          (ref 'pkgs '())
        'wasm-libs     (ref 'wasm-libs '())
        'local-pkgs    (map resolve (ref 'local-pkgs '()))
        'public        (and public (resolve public))
        'target        (normalize-target (ref 'target 'browser))
        ;; App-supplied emcc link JS, resolved to absolute paths. They ship into
        ;; the app's target surface only (see build/stages.rkt make-wasm).
        'pre-js        (resolve-list 'pre-js)
        'post-js       (resolve-list 'post-js)
        'extern-pre-js (resolve-list 'extern-pre-js)
        'hooks         hooks))

;; Load an app manifest and build it. `dest` defaults to <app-dir>/dist;
;; scheme/racket/force pass through from the CLI.
(define (run-app-manifest app-dir
                          #:dest [dest #f]
                          #:scheme [scheme #f]
                          #:racket [racket #f]
                          #:runtime-pkg [runtime-pkg #f]
                          #:force? [force? #f]
                          #:emcc-flags [emcc-flags ""])
  (define m (read-app-manifest app-dir))
  (define out (or dest (build-path (hash-ref m 'dir) "dist")))
  (make-wasm-racket
   #:dest          out
   #:pkgs          (hash-ref m 'pkgs)
   #:wasm-libs     (hash-ref m 'wasm-libs)
   #:local-pkgs    (hash-ref m 'local-pkgs)
   #:public        (hash-ref m 'public)
   #:target        (hash-ref m 'target)
   #:pre-js        (hash-ref m 'pre-js)
   #:post-js       (hash-ref m 'post-js)
   #:extern-pre-js (hash-ref m 'extern-pre-js)
   #:scheme        scheme
   #:racket        racket
   #:runtime-pkg   runtime-pkg
   #:force?        force?
   #:emcc-flags    emcc-flags)
  ;; Post-build hook: dist/ is fully assembled now (make-wasm-racket is
  ;; synchronous). Hand the hook a context hash so it can generate/transform
  ;; files into dist/ -- e.g. the IDE merges its examples into ide.js here.
  (define post-build (hash-ref (hash-ref m 'hooks) 'post-build #f))
  (when post-build
    (post-build (hash 'dist    (path->complete-path (->path out))
                      'app-dir  (hash-ref m 'dir)
                      'target   (hash-ref m 'target)))))

;; Load an app manifest and emit a distributable binary package (runtime set +
;; build-metadata + a .tar.gz) for its config into `dest` (default
;; <app-dir>/package). The package is app-config-specific (its key covers pkgs/
;; wasm-libs/local-pkgs and, for link-JS apps, the targeted surface) but ships
;; the union of surfaces -- `app <dir> --runtime <dest>` assembles against it.
(define (package-app-manifest app-dir
                              #:dest [dest #f]
                              #:scheme [scheme #f]
                              #:racket [racket #f]
                              #:force? [force? #f])
  (define m (read-app-manifest app-dir))
  (define (->paths xs) (map (lambda (p) (path->complete-path (->path p))) xs))
  (build-package
   #:dest          (or dest (build-path (hash-ref m 'dir) "package"))
   #:pkgs          (->names (hash-ref m 'pkgs))
   #:wasm-deps     (->names (hash-ref m 'wasm-libs))
   #:local-pkgs    (->paths (hash-ref m 'local-pkgs))
   #:target        (hash-ref m 'target)
   #:pre-js        (->paths (hash-ref m 'pre-js))
   #:post-js       (->paths (hash-ref m 'post-js))
   #:extern-pre-js (->paths (hash-ref m 'extern-pre-js))
   #:scheme        scheme
   #:racket        racket
   #:force?        force?))

;; Load an app manifest and emit a standalone, *package-blank* cross-compiler SDK
;; into `dest` (default <app-dir>/cross-sdk): the cross-compiler retarget files +
;; the base `tpb32l` cross-root, built emsdk-free. The SDK carries no app
;; packages (a consumer adds them via cross-install), so only the manifest's
;; native-dep profile (`wasm-libs`) is read.
(define (cross-sdk-app-manifest app-dir
                                #:dest [dest #f]
                                #:scheme [scheme #f]
                                #:racket [racket #f])
  (define m (read-app-manifest app-dir))
  ;; A pure, package-blank cross-compiler SDK (app packages are added via
  ;; cross-install); only the native-dep profile (`wasm-libs`) matters.
  (build-cross-sdk
   #:dest       (or dest (build-path (hash-ref m 'dir) "cross-sdk"))
   #:wasm-deps  (->names (hash-ref m 'wasm-libs))
   #:scheme     scheme
   #:racket     racket))

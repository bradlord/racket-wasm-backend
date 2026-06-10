#lang racket/base
;; The cross-build sequence. Hybrid model: the delicate in-tree interleave
;; (wasm-deps -> kernel build -> pkg install -> wasm-setup -> emcc link) lives in
;; the patched main.zuo / cs/c/build.zuo `wasm` target, which is the proven path.
;; This module owns the *outside* of that: ensure clone+delta, resolve host
;; toolchains, invoke `make wasm` with the buildit.sh-equivalent variables, and
;; collect the outputs into dist/.
(require racket/file
         racket/path
         racket/string
         "config.rkt"
         "util.rkt"
         "upstream.rkt"
         "patches.rkt"
         "toolchain.rkt"
         "cache.rkt"
         "metadata.rkt"
         "pack.rkt")

(provide build-runtime build-package collect-outputs make-wasm
         build-cross-sdk package-cross-sdk)

(define (emsdk-ready?)
  (and (find-executable-path "emcc")
       (find-executable-path "emconfigure")))

(define (require-emsdk!)
  (unless (emsdk-ready?)
    (error 'build
           (string-append "emcc/emconfigure not on PATH. Source the emsdk first:\n"
                          "  source <emsdk>/emsdk_env.sh\n"
                          "then re-run."))))

;; Run `make wasm` (or another target) in the clone root, mirroring buildit.sh.
;; `local-pkgs` is a space-joined string of absolute local-package source dirs;
;; main.zuo's install-base-pkgs `--copy`-installs them into share/pkgs.
;;
;; `pre-js`/`post-js`/`extern-pre-js` are the app's emcc link-JS files (lists of
;; absolute paths); `app-target` ('node/'browser) is the surface they target. They
;; flow as the LINK_*_JS / APP_TARGET make vars -> main.zuo (propagation) ->
;; cs/c/build.zuo's `wasm` link, which appends them to the targeted surface only.
;; Like LOCAL_PKGS, these vars are shell-split downstream, so the paths must not
;; contain spaces.
(define (make-wasm #:target [target "wasm"]
                   #:scheme scheme #:racket racket
                   #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs [local-pkgs ""]
                   #:pre-js [pre-js '()] #:post-js [post-js '()]
                   #:extern-pre-js [extern-pre-js '()] #:app-target [app-target 'browser])
  ;; SETUP_MACHINE_FLAGS mirrors buildit.sh's `-MCR \`pwd\`/build/zo:` with pwd =
  ;; the make working dir (the clone root).
  (define setup-flags
    (string-append "-MCR " (path->string (path->complete-path clone-dir)) "/build/zo:"))
  ;; A list of paths -> the space-joined absolute-path string the LINK_*_JS make
  ;; vars want ("" = none).
  (define (join-paths xs)
    (string-join (map (lambda (p) (path->string (path->complete-path p))) xs) " "))
  (info-msg "make ~a  (PKGS=~s WASM_DEPS=~s LOCAL_PKGS=~s APP_TARGET=~s)"
            target pkgs wasm-deps local-pkgs app-target)
  (run "make" #:dir clone-dir
       #:args (list target
                    (string-append "SCHEME=" scheme)
                    (string-append "RACKET=" racket)
                    (string-append "PKGS=" pkgs)
                    (string-append "WASM_DEPS=" wasm-deps)
                    (string-append "LOCAL_PKGS=" local-pkgs)
                    (string-append "LINK_PRE_JS=" (join-paths pre-js))
                    (string-append "LINK_POST_JS=" (join-paths post-js))
                    (string-append "LINK_EXTERN_PRE_JS=" (join-paths extern-pre-js))
                    (string-append "APP_TARGET=" (symbol->string (normalize-target app-target)))
                    (string-append "SETUP_MACHINE_FLAGS=" setup-flags))))

;; The runtime set (link products + the separate package payload share.data*)
;; is `runtime-output-names` (config.rkt) -- shared with the cache so the cached
;; set and the collected set can't drift. share.data / share.data.js are produced
;; by `pack-share-data` (build/pack.rkt, a pure-Racket file_packager), not the
;; link -- see that module and build-wasm.md "Packages as a separate data file".

;; Host-side glue for the *browser* surface, copied from the repo (runtime-glue/)
;; rather than staged by the link: shell-worker.js bootstraps the browser runtime
;; worker. Node apps don't need it. serve.rkt (the COOP/COEP dev server) lives in
;; runtime-glue/ and is run in place by `serve` -- it is NOT copied into dist/.
(define browser-glue-files '("shell-worker.js"))

;; The browser surface's package payload (share.data + share.data.js) is built
;; as a SEPARATE data file by `pack-share-data` (build/pack.rkt) -- a pure-Racket
;; file_packager, no emsdk -- instead of baking the package tree into the emcc
;; link. This decouples package changes from the (expensive) relink: re-install
;; packages and re-run pack, no emcc link needed. Node (scheme.*) is unaffected
;; -- it still bakes packages into scheme.data.

;; Assemble dist/: the runtime binaries from the clone's link output, the
;; host-side glue from the repo, and a page surface from the repo. `target`
;; selects which surface's runtime ships (browser = scheme-web.* + share.data*;
;; node = scheme.*), defaulting to browser. The surface dir defaults to the IDE
;; -- make-wasm-racket overrides #:surface-dir / #:dest / #:target to assemble an
;; arbitrary app from its own public/ dir.
(define (collect-outputs #:dest        [dest dist-dir]
                         #:surface-dir [surface-dir (build-path ide-app-dir "public")]
                         #:target      [target 'browser]
                         #:runtime-src [runtime-src (clone-wasm-out)])
  (unless (directory-exists? runtime-src)
    (error 'collect-outputs "no runtime output dir at ~a (did the link run / cache exist?)" runtime-src))
  (make-directory* dest)
  (define (copy-into from name)
    (define s (build-path from name))
    (when (file-exists? s)
      (define d (build-path dest name))
      (when (file-exists? d) (delete-file d))
      (copy-file s d)))
  ;; 1. Runtime binaries for this surface (from the clone's link output, or cache).
  (for ([n (in-list (runtime-names-for-target target))]) (copy-into runtime-src n))
  ;; 2. Host-side glue (from the repo) -- browser only.
  (when (eq? (normalize-target target) 'browser)
    (for ([n (in-list browser-glue-files)]) (copy-into runtime-glue-dir n)))
  ;; 3. Surface assets (from the repo; default = the IDE). Copies every file in
  ;;    the surface dir, so an app's public/ html+js+css all ship.
  (when (and surface-dir (directory-exists? surface-dir))
    (for ([p (in-list (directory-list surface-dir))]
          #:when (file-exists? (build-path surface-dir p)))
      (copy-into surface-dir (path->string p))))
  (info-msg "outputs collected into ~a" dest))

;; The runtime-output files actually present in `dir` (a cache entry / package /
;; dist), for the metadata's `runtime-files`.
(define (present-runtime-files dir)
  (for/list ([n (in-list runtime-output-names)]
             #:when (file-exists? (build-path dir n)))
    n))

;; Write the build-metadata sidecar into `dir` describing the assembled output:
;; the freshly computed components/key plus the build's Racket version.
(define (write-metadata-into! dir key components racket-version)
  (write-build-metadata!
   dir
   (make-build-metadata #:key key #:components components
                        #:racket-version racket-version
                        #:runtime-files (present-runtime-files dir))))

;; Assemble an app's surface against an *external* prebuilt binary package
;; (`pkg`, a dir of runtime files + a build-metadata sidecar) -- no clone, no
;; `make`, no emsdk. Verifies the app's expected `key`/`components` against the
;; package's recorded build-key; a mismatch errors (component-by-component)
;; unless `force?`, which downgrades it to a warning. The assembled `dist/`
;; records the package's own provenance (it describes the actual binaries).
(define (assemble-from-package pkg key components #:dest dest #:surface-dir surface-dir
                              #:target target #:force? force?)
  (define meta (read-build-metadata pkg))
  (unless meta
    (error 'app "runtime package ~a has no build metadata (~a) -- is it a racket-wasm package?"
           pkg build-metadata-filename))
  (define pkg-key (hash-ref meta 'build-key #f))
  (unless (equal? pkg-key key)
    (define report (key-mismatch-report key components meta))
    (if force?
        (info-msg "WARNING (forced): ~a" report)
        (error 'app "~a\n(pass --force to assemble against this package anyway)" report)))
  ;; The target's runtime files must be present in the package.
  (for ([n (in-list (runtime-names-for-target target))])
    (unless (file-exists? (build-path pkg n))
      (error 'app "runtime package ~a is missing ~a (needed for target ~a)"
             pkg n (normalize-target target))))
  (info-msg "assembling from runtime package ~a (build-key ~a), no build" pkg pkg-key)
  (collect-outputs #:dest dest #:surface-dir surface-dir #:target target #:runtime-src pkg)
  ;; dist describes the binaries it actually contains -- i.e. the package's.
  (write-metadata-into! dest (or pkg-key key) (hash-ref meta 'components components)
                        (hash-ref meta 'racket-version #f)))

;; Core build sequence, parameterized by output destination and surface. Ensure
;; the clone+delta, resolve host toolchains, run `make wasm`, pack the package
;; payload, and assemble outputs into `dest` with `surface-dir` as the page.
;; `pkgs`/`wasm-deps` are the make-var strings; scheme/racket are explicit paths
;; or #f to resolve/build. This is the shared engine for both the CLI `build`
;; (dist/ + the IDE surface) and the app API (`build/app.rkt` make-wasm-racket).
;;
;; `runtime-pkg` (a prebuilt binary package dir) takes a separate path entirely:
;; assemble against it with no clone/make/emsdk after a build-key check -- see
;; `assemble-from-package`.
(define (build-runtime #:pkgs pkgs #:wasm-deps wasm-deps
                       #:local-pkgs [local-pkgs '()]
                       #:pre-js [pre-js '()] #:post-js [post-js '()]
                       #:extern-pre-js [extern-pre-js '()]
                       #:scheme [scheme-opt #f] #:racket [racket-opt #f]
                       #:dest [dest dist-dir]
                       #:surface-dir [surface-dir (build-path ide-app-dir "public")]
                       #:target [target 'browser]
                       #:runtime-pkg [runtime-pkg #f]
                       #:force? [force? #f])
  ;; The runtime is fully determined by (upstream-sha, delta, wasm-deps, pkgs,
  ;; local-pkgs) plus, when present, the app's link JS + the surface it targets.
  ;; If we've built this exact config before, assemble straight from the cache --
  ;; no `make`, no relink, and crucially no mutation of the shared clone, so an
  ;; app with a different config can't clobber this one (Phase 3).
  (define link-js (append extern-pre-js pre-js post-js))
  (define components (build-key-components #:pkgs pkgs #:wasm-deps wasm-deps
                                           #:local-pkgs local-pkgs
                                           #:link-js link-js #:target target))
  (define key (key-from-components components))
  (cond
    [runtime-pkg
     (assemble-from-package (->path runtime-pkg) key components
                            #:dest dest #:surface-dir surface-dir
                            #:target target #:force? force?)]
    [(and (not force?) (cache-complete? key))
     (info-msg "runtime cache hit (~a): assembling from cache, no build" key)
     (define rv (let ([m (read-build-metadata (cache-dir-for key))])
                  (and m (hash-ref m 'racket-version #f))))
     (collect-outputs #:dest dest #:surface-dir surface-dir #:target target
                      #:runtime-src (cache-dir-for key))
     (write-metadata-into! dest key components rv)]
    [else
     (require-emsdk!)
     ;; Ensure the clone exists and the delta is applied (idempotent; preserves
     ;; build artifacts from a prior run -- only sync wipes the tree).
     (unless (directory-exists? (build-path clone-dir ".git")) (sync))
     (apply-delta)
     (define scheme (resolve-host-scheme scheme-opt))
     (define racket (resolve-host-racket racket-opt))
     (make-wasm #:scheme scheme #:racket racket #:pkgs pkgs #:wasm-deps wasm-deps
                #:local-pkgs (string-join (map (lambda (p) (path->string (path->complete-path p)))
                                               local-pkgs)
                                          " ")
                #:pre-js pre-js #:post-js post-js #:extern-pre-js extern-pre-js
                #:app-target target)
     ;; Pack the browser package payload as a separate data file (the browser
     ;; link no longer bakes it in); collect picks up share.data/share.data.js.
     (pack-share-data)
     ;; Cache the runtime set for this config so the next build of it is a copy.
     (snapshot-runtime! key (clone-wasm-out))
     (define rv (host-racket-version racket))
     ;; Record provenance into the cache entry (so `package` and later hits can
     ;; carry it) and into dist.
     (write-metadata-into! (cache-dir-for key) key components rv)
     (collect-outputs #:dest dest #:surface-dir surface-dir #:target target
                      #:runtime-src (clone-wasm-out))
     (write-metadata-into! dest key components rv)]))

(define (->path p) (if (path? p) p (string->path p)))

;; Build (or reuse the cache for) a config and emit a *distributable* binary
;; package into `dest`: the full runtime set (`runtime-output-names`, both
;; surfaces) + the build-metadata sidecar, plus a sibling `<dest>.tar.gz`. The
;; package is a portable cache entry -- `app <dir> --runtime <dest>` assembles
;; against it with no clone/make. `target` only affects the key when the app
;; supplies link JS (which is surface-specific); the package always ships the
;; union of surfaces.
(define (build-package #:pkgs pkgs #:wasm-deps wasm-deps
                       #:local-pkgs [local-pkgs '()]
                       #:pre-js [pre-js '()] #:post-js [post-js '()]
                       #:extern-pre-js [extern-pre-js '()]
                       #:scheme [scheme-opt #f] #:racket [racket-opt #f]
                       #:dest dest
                       #:target [target 'browser]
                       #:force? [force? #f])
  (define link-js (append extern-pre-js pre-js post-js))
  (define components (build-key-components #:pkgs pkgs #:wasm-deps wasm-deps
                                           #:local-pkgs local-pkgs
                                           #:link-js link-js #:target target))
  (define key (key-from-components components))
  ;; Ensure the runtime set for this config is in the cache (build on a miss),
  ;; without needing a surface -- assemble into a throwaway dir.
  (define scratch (make-temporary-file "rktwasm-pkg-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (build-runtime #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs local-pkgs
                    #:pre-js pre-js #:post-js post-js #:extern-pre-js extern-pre-js
                    #:scheme scheme-opt #:racket racket-opt
                    #:dest scratch #:surface-dir #f #:target target #:force? force?))
   (lambda () (when (directory-exists? scratch) (delete-directory/files scratch))))
  (define src (cache-dir-for key))
  (define pkg-dest (->path dest))
  (make-directory* pkg-dest)
  (for ([n (in-list runtime-output-names)])
    (define s (build-path src n))
    (when (file-exists? s)
      (define d (build-path pkg-dest n))
      (when (file-exists? d) (delete-file d))
      (copy-file s d)))
  (define rv (let ([m (read-build-metadata src)]) (and m (hash-ref m 'racket-version #f))))
  (write-metadata-into! pkg-dest key components rv)
  ;; Single distributable artifact next to the dir: <name>.tar.gz of its contents.
  (define parent (path-only (path->complete-path (simplify-path pkg-dest))))
  (define base (file-name-from-path (simplify-path (path->complete-path pkg-dest))))
  (define tgz (path-replace-extension (build-path parent base) ".tar.gz"))
  (when (file-exists? tgz) (delete-file tgz))
  (run "tar" #:dir parent
       #:args (list "-czf" (path->string tgz) (path->string base)))
  (info-msg "binary package -> ~a (build-key ~a)\n    archive -> ~a"
            pkg-dest key tgz))

;; --- cross-compiler SDK -------------------------------------------------
;;
;; A standalone artifact (NOT part of the runtime binary package): the
;; cross-compiler retarget files + a cross-root of `tpb32l` dependency bytecode,
;; enough for a host Racket of the same version to cross-compile NEW packages
;; for `tpb32l` with no clone and no emsdk. Producing it is a normal Racket
;; pb/`tpb32l` cross-compile (host Chez + host Racket) -- the cross-compiler and
;; the `tpb32l` `.zo` are emscripten-INDEPENDENT, so emsdk is never needed (and
;; `require-emsdk!` is deliberately NOT called). See build-wasm.md and
;; config.rkt `cross-sdk-layout`.

;; Copy one (dest-relative . clone-source) layout entry, file or tree.
(define (copy-sdk-entry! dest-root dest-rel src)
  (define dst (build-path dest-root dest-rel))
  (define-values (base name dir?) (split-path dst))
  (make-directory* base)
  (cond
    [(directory-exists? src) (copy-directory/files src dst)]
    [(file-exists? src)      (copy-file src dst)]
    [else (error 'cross-sdk "missing SDK input (did the cross build run?): ~a" src)]))

;; Collect the cross-SDK file-set (config.rkt `cross-sdk-layout`) from the clone
;; into `dest`, write the build-metadata sidecar (kind 'cross-sdk + the host
;; arch/version gate), and create a sibling `<dest>.tar.gz`. The clone must
;; already hold the cross build's output (`build-cross-sdk` ensures this).
(define (package-cross-sdk #:key key #:components components #:dest dest
                           #:scheme scheme #:racket racket)
  (define dest* (->path dest))
  (when (directory-exists? dest*) (delete-directory/files dest*))
  (make-directory* dest*)
  (for ([e (in-list (cross-sdk-layout))])
    (copy-sdk-entry! dest* (car e) (cdr e)))
  (write-build-metadata!
   dest*
   (make-build-metadata #:key key #:components components #:kind 'cross-sdk
                        #:racket-version (host-racket-version racket)
                        #:host-machine   (host-scheme-machine scheme)
                        #:chez-version   (host-scheme-version scheme)))
  (define parent (path-only (path->complete-path (simplify-path dest*))))
  (define base (file-name-from-path (simplify-path (path->complete-path dest*))))
  (define tgz (path-replace-extension (build-path parent base) ".tar.gz"))
  (when (file-exists? tgz) (delete-file tgz))
  (run "tar" #:dir parent
       #:args (list "-czf" (path->string tgz) (path->string base)))
  (info-msg "cross-compiler SDK -> ~a (build-key ~a, host ~a)\n    archive -> ~a"
            dest* key (host-scheme-machine scheme) tgz))

;; Build (emsdk-free) the cross-compiler + `tpb32l` cross-root for a config and
;; emit a distributable SDK into `dest`. The key is computed from the package
;; set only (no link JS / surface -- the SDK is surface-independent), so it
;; matches the runtime package built from the same `pkgs`/`wasm-deps`/locals.
(define (build-cross-sdk #:pkgs pkgs #:wasm-deps wasm-deps
                         #:local-pkgs [local-pkgs '()]
                         #:scheme [scheme-opt #f] #:racket [racket-opt #f]
                         #:dest dest)
  (define components (build-key-components #:pkgs pkgs #:wasm-deps wasm-deps
                                           #:local-pkgs local-pkgs))
  (define key (key-from-components components))
  ;; No `require-emsdk!`: the SDK is pure `tpb32l`, no emcc anywhere.
  (unless (directory-exists? (build-path clone-dir ".git")) (sync))
  (apply-delta)
  (define scheme (resolve-host-scheme scheme-opt))
  (define racket (resolve-host-racket racket-opt))
  (make-wasm #:target "wasm-cross-sdk" #:scheme scheme #:racket racket
             #:pkgs pkgs #:wasm-deps wasm-deps
             #:local-pkgs (string-join
                           (map (lambda (p) (path->string (path->complete-path p)))
                                local-pkgs)
                           " "))
  (package-cross-sdk #:key key #:components components #:dest dest
                     #:scheme scheme #:racket racket))

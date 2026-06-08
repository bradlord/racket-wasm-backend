#lang racket/base
;; The cross-build sequence. Hybrid model: the delicate in-tree interleave
;; (wasm-deps -> kernel build -> pkg install -> wasm-setup -> emcc link) lives in
;; the patched main.zuo / cs/c/build.zuo `wasm` target, which is the proven path.
;; This module owns the *outside* of that: ensure clone+delta, resolve host
;; toolchains, invoke `make wasm` with the buildit.sh-equivalent variables, and
;; collect the outputs into dist/.
(require racket/file
         racket/list
         racket/path
         racket/string
         "config.rkt"
         "util.rkt"
         "upstream.rkt"
         "patches.rkt"
         "toolchain.rkt"
         "cache.rkt")

(provide build build-runtime collect-outputs make-wasm pack-share-data)

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
(define (make-wasm #:target [target "wasm"]
                   #:scheme scheme #:racket racket
                   #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs [local-pkgs ""])
  ;; SETUP_MACHINE_FLAGS mirrors buildit.sh's `-MCR \`pwd\`/build/zo:` with pwd =
  ;; the make working dir (the clone root).
  (define setup-flags
    (string-append "-MCR " (path->string (path->complete-path clone-dir)) "/build/zo:"))
  (info-msg "make ~a  (PKGS=~s WASM_DEPS=~s LOCAL_PKGS=~s)" target pkgs wasm-deps local-pkgs)
  (run "make" #:dir clone-dir
       #:args (list target
                    (string-append "SCHEME=" scheme)
                    (string-append "RACKET=" racket)
                    (string-append "PKGS=" pkgs)
                    (string-append "WASM_DEPS=" wasm-deps)
                    (string-append "LOCAL_PKGS=" local-pkgs)
                    (string-append "SETUP_MACHINE_FLAGS=" setup-flags))))

;; The runtime set (link products + the separate package payload share.data*)
;; is `runtime-output-names` (config.rkt) -- shared with the cache so the cached
;; set and the collected set can't drift. share.data / share.data.js are produced
;; by `pack-share-data` (file_packager), not the link -- see that function and
;; build-wasm.md "Packages as a separate data file".

;; Surface-agnostic host-side glue, copied from the repo (runtime-glue/) rather
;; than staged by the link: shell-worker.js bootstraps the browser runtime
;; worker; serve.rkt is the COOP/COEP dev server. Any browser surface needs them.
(define glue-files '("shell-worker.js" "serve.rkt"))

;; Parse a links.rktd for entries whose path resolves to /pkgs/<name> -- the
;; `(up up #"pkgs" #"name")` form, which `up up` escapes /share to / before
;; pkgs/name, i.e. in-tree packages linked in place. Mirrors `links-pkgs-roots`
;; in racket/src/cs/c/build.zuo (keep the two in sync). Copied catalog packages
;; instead use the `(#"pkgs" #"name")` form, which resolves under /share/pkgs
;; and is covered by the wholesale share/pkgs preload -- so those are not
;; returned here. Each links entry is `(<tag> <path> [<version-regexp>])`.
(define (links-pkgs-roots links-file)
  (filter values
    (for/list ([e (in-list (call-with-input-file links-file read))])
      (define path (and (pair? e) (pair? (cdr e)) (cadr e)))
      (and (list? path)
           (= (length path) 4)
           (eq? (car path) 'up)
           (eq? (cadr path) 'up)
           (equal? (caddr path) #"pkgs")
           (bytes->string/utf-8 (cadddr path))))))

;; Locate Emscripten's file_packager.py: next to emcc (emsdk lays it out as
;; <emscripten>/tools/file_packager.py while putting <emscripten> on PATH),
;; falling back to $EMSDK.
(define (file-packager-path)
  (define emcc (find-executable-path "emcc"))
  (define candidates
    (append
     (if emcc (list (build-path (path-only emcc) "tools" "file_packager.py")) '())
     (let ([emsdk (getenv "EMSDK")])
       (if emsdk
           (list (build-path emsdk "upstream" "emscripten" "tools" "file_packager.py"))
           '()))))
  (or (for/or ([c (in-list candidates)]) (and (file-exists? c) c))
      (error 'pack-share-data
             "file_packager.py not found (looked next to emcc and under $EMSDK)")))

;; Build the browser surface's package payload as a SEPARATE Emscripten data
;; file (share.data + share.data.js) via file_packager, instead of baking the
;; package tree into the emcc link. This decouples package changes from the
;; (expensive) relink: re-install packages and re-run this, no emcc link needed.
;; The preload set mirrors `share-preloads` in cs/c/build.zuo: the wholesale
;; share/pkgs tree, the installation links file, and every in-tree /pkgs/<name>
;; the links file points at. Outputs land in `dest` (the wasm out dir) next to
;; scheme-web.*, ready for collect-outputs. Node (scheme.*) is unaffected -- it
;; still bakes packages into scheme.data.
(define (pack-share-data #:dest [dest (clone-wasm-out)])
  (require-emsdk!)
  (define fp (file-packager-path))
  (define share-pkgs (build-path clone-dir "racket" "share" "pkgs"))
  (define links (build-path clone-dir "racket" "share" "links.rktd"))
  (unless (directory-exists? share-pkgs)
    (error 'pack-share-data
           "no installed package tree at ~a (run a build first)" share-pkgs))
  (make-directory* dest)
  (define (preload src dst)
    (list "--preload" (string-append (path->string src) "@" dst)))
  ;; In-tree packages linked in place (source bootstrap); empty for a
  ;; binary-catalog consume where everything is copied under share/pkgs.
  (define in-tree
    (if (file-exists? links)
        (append-map (lambda (name)
                      (define src (build-path clone-dir "pkgs" name))
                      (if (directory-exists? src)
                          (preload src (string-append "/pkgs/" name))
                          '()))
                    (links-pkgs-roots links))
        '()))
  (define preloads
    (append (preload share-pkgs "/share/pkgs")
            (if (file-exists? links) (preload links "/share/links.rktd") '())
            in-tree))
  (info-msg "packing share.data via file_packager (~a preload entries) -> ~a"
            (length (filter (lambda (s) (string=? s "--preload")) preloads))
            dest)
  ;; file_packager writes share.data + share.data.js into the cwd; run it in
  ;; `dest`. Source paths are absolute, so the cwd does not affect them. One
  ;; loader serves both surfaces (browser fetch / node readFileSync). We do
  ;; NOT pass --use-preload-cache: the package payload is small (~10MB; the
  ;; browser already caches the big core .data via the link's own
  ;; --use-preload-cache and re-fetches share.data through the HTTP cache),
  ;; and the cache path's IndexedDB probe throws under node, dumping a stack
  ;; trace on every boot. Caching this tier buys little and isn't worth that.
  (run "python3" #:dir dest
       #:args (append
               (list (path->string fp) "share.data")
               preloads
               (list "--js-output=share.data.js"))))

;; Assemble dist/: the runtime binaries from the clone's link output, the
;; host-side glue from the repo, and a page surface from the repo. The surface
;; defaults to the IDE (surfaces/ide) -- Phase 1's make-wasm-racket overrides
;; #:surface-dir / #:dest to assemble an arbitrary app from its own public/ dir.
(define (collect-outputs #:dest        [dest dist-dir]
                         #:surface-dir [surface-dir (build-path surfaces-dir "ide")]
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
  ;; 1. Runtime binaries (from the clone's link output, or the runtime cache).
  (for ([n (in-list runtime-output-names)]) (copy-into runtime-src n))
  ;; 2. Host-side glue (from the repo).
  (for ([n (in-list glue-files)]) (copy-into runtime-glue-dir n))
  ;; 3. Surface assets (from the repo; default = the IDE). Copies every file in
  ;;    the surface dir, so an app's public/ html+js+css all ship.
  (when (and surface-dir (directory-exists? surface-dir))
    (for ([p (in-list (directory-list surface-dir))]
          #:when (file-exists? (build-path surface-dir p)))
      (copy-into surface-dir (path->string p))))
  (info-msg "outputs collected into ~a" dest))

;; Core build sequence, parameterized by output destination and surface. Ensure
;; the clone+delta, resolve host toolchains, run `make wasm`, pack the package
;; payload, and assemble outputs into `dest` with `surface-dir` as the page.
;; `pkgs`/`wasm-deps` are the make-var strings; scheme/racket are explicit paths
;; or #f to resolve/build. This is the shared engine for both the CLI `build`
;; (dist/ + the IDE surface) and the app API (`build/app.rkt` make-wasm-racket).
(define (build-runtime #:pkgs pkgs #:wasm-deps wasm-deps
                       #:local-pkgs [local-pkgs '()]
                       #:scheme [scheme-opt #f] #:racket [racket-opt #f]
                       #:dest [dest dist-dir]
                       #:surface-dir [surface-dir (build-path surfaces-dir "ide")]
                       #:force? [force? #f])
  ;; The runtime is fully determined by (upstream-sha, delta, wasm-deps, pkgs,
  ;; local-pkgs). If we've built this exact config before, assemble straight from
  ;; the cache -- no `make`, no relink, and crucially no mutation of the shared
  ;; clone, so an app with a different config can't clobber this one (Phase 3).
  (define key (build-key #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs local-pkgs))
  (cond
    [(and (not force?) (cache-complete? key))
     (info-msg "runtime cache hit (~a): assembling from cache, no build" key)
     (collect-outputs #:dest dest #:surface-dir surface-dir
                      #:runtime-src (cache-dir-for key))]
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
                                          " "))
     ;; Pack the browser package payload as a separate data file (the browser
     ;; link no longer bakes it in); collect picks up share.data/share.data.js.
     (pack-share-data)
     ;; Cache the runtime set for this config so the next build of it is a copy.
     (snapshot-runtime! key (clone-wasm-out))
     (collect-outputs #:dest dest #:surface-dir surface-dir
                      #:runtime-src (clone-wasm-out))]))

;; Full build (CLI). opts is a hash with optional keys:
;;   'pkgs 'wasm-deps (strings), 'scheme 'racket (paths)
;; Produces dist/ with the default IDE surface.
(define (build opts)
  (build-runtime #:pkgs       (hash-ref opts 'pkgs (string-join default-pkgs " "))
                 #:wasm-deps   (hash-ref opts 'wasm-deps default-wasm-deps)
                 #:local-pkgs  default-local-pkgs
                 #:scheme      (hash-ref opts 'scheme #f)
                 #:racket      (hash-ref opts 'racket #f)
                 #:force?      (hash-ref opts 'force? #f)))

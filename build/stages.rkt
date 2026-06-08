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
         "toolchain.rkt")

(provide build collect-outputs make-wasm pack-share-data)

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
(define (make-wasm #:target [target "wasm"]
                   #:scheme scheme #:racket racket
                   #:pkgs pkgs #:wasm-deps wasm-deps)
  ;; SETUP_MACHINE_FLAGS mirrors buildit.sh's `-MCR \`pwd\`/build/zo:` with pwd =
  ;; the make working dir (the clone root).
  (define setup-flags
    (string-append "-MCR " (path->string (path->complete-path clone-dir)) "/build/zo:"))
  (info-msg "make ~a  (PKGS=~s WASM_DEPS=~s)" target pkgs wasm-deps)
  (run "make" #:dir clone-dir
       #:args (list target
                    (string-append "SCHEME=" scheme)
                    (string-append "RACKET=" racket)
                    (string-append "PKGS=" pkgs)
                    (string-append "WASM_DEPS=" wasm-deps)
                    (string-append "SETUP_MACHINE_FLAGS=" setup-flags))))

;; Copy the link outputs out of the clone into dist/. share.data / share.data.js
;; are the browser surface's package payload, produced by `pack-share-data`
;; (file_packager) rather than the emcc link -- see that function and
;; build-wasm.md "Packages as a separate data file".
(define output-names
  '("scheme.js" "scheme.wasm" "scheme.data"
    "scheme-web.js" "scheme-web.wasm" "scheme-web.data"
    "share.data" "share.data.js"
    "ide.html" "ide.js" "shell-worker.js" "serve.rkt"))

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

(define (collect-outputs)
  (define src (clone-wasm-out))
  (unless (directory-exists? src)
    (error 'collect-outputs "no wasm output dir at ~a (did the link run?)" src))
  (make-directory* dist-dir)
  (for ([n (in-list output-names)])
    (define s (build-path src n))
    (when (file-exists? s)
      (define d (build-path dist-dir n))
      (when (file-exists? d) (delete-file d))
      (copy-file s d)))
  (info-msg "outputs collected into ~a" dist-dir))

;; Full build. opts is a hash with optional keys:
;;   'pkgs 'wasm-deps (strings), 'scheme 'racket (paths), 'binary-pkgs? (bool)
(define (build opts)
  (require-emsdk!)
  (define pkgs      (hash-ref opts 'pkgs (string-join default-pkgs " ")))
  (define wasm-deps (hash-ref opts 'wasm-deps default-wasm-deps))
  ;; Ensure the clone exists and the delta is applied (idempotent; preserves
  ;; build artifacts from a prior run -- only sync wipes the tree).
  (unless (directory-exists? (build-path clone-dir ".git")) (sync))
  (apply-delta)
  (define scheme (resolve-host-scheme (hash-ref opts 'scheme #f)))
  (define racket (resolve-host-racket (hash-ref opts 'racket #f)))
  (make-wasm #:scheme scheme #:racket racket #:pkgs pkgs #:wasm-deps wasm-deps)
  ;; Pack the browser package payload as a separate data file (the browser
  ;; link no longer bakes it in); collect picks up share.data/share.data.js.
  (pack-share-data)
  (collect-outputs))

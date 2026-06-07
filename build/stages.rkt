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
         "toolchain.rkt")

(provide build collect-outputs make-wasm)

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

;; Copy the link outputs out of the clone into dist/.
(define output-names
  '("scheme.js" "scheme.wasm" "scheme.data"
    "scheme-web.js" "scheme-web.wasm" "scheme-web.data"
    "ide.html" "ide.js" "shell-worker.js" "serve.rkt"))

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
  (collect-outputs))

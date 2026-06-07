#lang racket/base
;; Resolve (and, for Chez, optionally build) the two host toolchains the cross
;; build needs:
;;   * a native *threaded* host Chez Scheme -- the cross-compiler host that
;;     generates the tpb32l boot files / xpatch (build-wasm.md stage 0/3).
;;   * a same-version host Racket -- the `raco setup` `--cross-server`.
;;
;; Both can be passed explicitly (--scheme / --racket). If --scheme is omitted
;; and none is found, a threaded Chez is bootstrapped in the clone's ChezScheme
;; tree (./configure --threads && make), exactly as build-wasm.md stage 0 does.
(require racket/file
         racket/path
         racket/string
         "config.rkt"
         "util.rkt")

(provide resolve-host-scheme resolve-host-racket)

;; --- host Chez ----------------------------------------------------------

(define chez-src (build-path clone-dir "racket" "src" "ChezScheme"))

;; Look for an already-built threaded host Chez:
;;   * a prior `make cs`:   racket/src/build/cs/c/ChezScheme/<mach>/bin/<mach>/scheme
;;   * a prior stage-0:     racket/src/ChezScheme/<mach>/bin/<mach>/scheme
(define (find-built-scheme)
  (define roots
    (list (build-path clone-dir "racket" "src" "build" "cs" "c" "ChezScheme")
          chez-src))
  (for*/first ([root (in-list roots)]
               #:when (directory-exists? root)
               [mach (in-list (if (directory-exists? root) (directory-list root) '()))]
               #:when (regexp-match? #rx"^t" (path->string mach)) ; threaded: t<arch>
               [exe (in-value (build-path root mach "bin" mach "scheme"))]
               #:when (file-exists? exe))
    exe))

(define (build-host-scheme!)
  (info-msg "no host Chez found; bootstrapping a threaded one (stage 0)")
  ;; Committed pb boot files + enableFrompb=yes let a plain ./configure build a
  ;; native threaded Chez without an existing scheme. See build-wasm.md stage 0.
  (run "sh" #:dir chez-src #:args (list "-c" "./configure --threads && make"))
  (or (find-built-scheme)
      (error 'toolchain "host Chez build completed but no scheme binary found under ~a" chez-src)))

(define (resolve-host-scheme [explicit #f])
  (define s (or explicit (find-built-scheme) (build-host-scheme!)))
  (define p (if (path? s) s (string->path s)))
  (unless (file-exists? p)
    (error 'toolchain "host Chez not executable: ~a" p))
  (info-msg "host Chez: ~a" p)
  (path->string (path->complete-path p)))

;; --- host Racket --------------------------------------------------------

(define (find-host-racket)
  ;; Prefer one inside the clone (a prior `make cs`), then PATH.
  (define in-clone (build-path clone-dir "racket" "bin" "racket"))
  (cond
    [(file-exists? in-clone) in-clone]
    [(find-executable-path "racket") => values]
    [else #f]))

(define (resolve-host-racket [explicit #f])
  (define r (or explicit (find-host-racket)))
  (unless r
    (error 'toolchain
           (string-append "no host Racket found. Pass --racket <path> to a Racket of the "
                          "same version as the pinned tree (it loads the version-stamped xpatch).")))
  (define p (if (path? r) r (string->path r)))
  (unless (file-exists? p)
    (error 'toolchain "host Racket not executable: ~a" p))
  (info-msg "host Racket: ~a" p)
  (path->string (path->complete-path p)))

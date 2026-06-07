#lang racket/base
;; Central configuration for the racket-wasm build orchestrator: the pinned
;; upstream commit (read from ../upstream.lock), default package / native-dep
;; selection, and the on-disk layout under .work/.
(require racket/runtime-path
         racket/path)

(provide (all-defined-out))

;; --- repo layout --------------------------------------------------------

;; build/ lives one level under the repo root.
(define-runtime-path build-dir ".")
(define repo-root (simplify-path (build-path build-dir 'up)))

(define (at-root . parts) (apply build-path repo-root parts))

(define patches-dir   (at-root "patches"))
(define overlay-dir   (at-root "overlay"))
(define work-dir      (at-root ".work"))
(define dist-dir      (at-root "dist"))
;; The cloned upstream tree.
(define clone-dir     (build-path work-dir "racket"))
;; Where the wasm link target emits its output inside the clone.
(define (clone-wasm-out)
  (build-path clone-dir "racket" "src" "build" "cs" "c" "wasm"))

;; --- pinned upstream ----------------------------------------------------

(define upstream-lock-path (at-root "upstream.lock"))

(define upstream-lock
  (call-with-input-file upstream-lock-path read))

(define (lock-ref key)
  (hash-ref upstream-lock key
            (lambda () (error 'config "upstream.lock missing key: ~a" key))))

(define upstream-url  (lock-ref 'url))
(define upstream-sha  (lock-ref 'sha))

;; --- build defaults (from the fork's buildit.sh active line) ------------

;; Packages cross-installed into the image. List `-lib` implementation
;; packages, not metapackages (see build-wasm.md "Binary-only package preload").
(define default-pkgs '("draw-lib" "datalog" "pict-lib"))

;; Native C library deps. "draw" is the cairo/pango stack alias; libffi is
;; always built regardless.
(define default-wasm-deps "draw")

;; Host toolchains: overridable on the CLI. #f means "resolve/build".
(define default-host-scheme #f)   ; native *threaded* Chez (cross-compiler host)
(define default-host-racket #f)   ; same-version host Racket (raco cross-server)

;; The target Chez machine type for the WASM build.
(define target-machine "tpb32l")

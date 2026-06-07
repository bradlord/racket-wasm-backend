#lang racket/base
;; The binary-only package catalog: a 4-stage clean rebuild that strips the
;; cross-compiled packages to .zo-only (build-deps pruned), shrinking the image.
;; Replaces the fork's rebuild-binary-catalog.sh. See build-wasm.md
;; "Binary-only package preload" for why each stage is required.
(require racket/file
         racket/path
         racket/string
         "config.rkt"
         "util.rkt"
         "upstream.rkt"
         "patches.rkt"
         "toolchain.rkt"
         "stages.rkt")

(provide rebuild-binary-catalog)

;; Paths inside the clone that the rebuild must clear for a clean source tree.
(define (clone-path . parts) (apply build-path clone-dir parts))
(define clear-targets
  (list (clone-path "racket" "src" ".wasm-pkgs-cache")
        (clone-path "racket" "share" "pkgs")
        (clone-path "racket" "share" "links.rktd")
        (clone-path "racket" "share" "info-cache.rktd")))

(define (clear! p)
  (when (or (file-exists? p) (directory-exists? p) (link-exists? p))
    (info-msg "clearing ~a" p)
    (delete-directory/files p)))

;; opts: same shape as stages.rkt's `build` (pkgs/wasm-deps/scheme/racket).
(define (rebuild-binary-catalog opts)
  (define pkgs      (hash-ref opts 'pkgs (string-join default-pkgs " ")))
  (define wasm-deps (hash-ref opts 'wasm-deps default-wasm-deps))
  (unless (directory-exists? (build-path clone-dir ".git")) (sync))
  (apply-delta)
  (define scheme (resolve-host-scheme (hash-ref opts 'scheme #f)))
  (define racket (resolve-host-racket (hash-ref opts 'racket #f)))
  (define (mk #:target [t "wasm"])
    (make-wasm #:target t #:scheme scheme #:racket racket
               #:pkgs pkgs #:wasm-deps wasm-deps))

  ;; (1) Clear so the bootstrap builds a fresh *source* tree (the strip needs it).
  (info-msg "stage 1/4: clearing prior pkg tree + catalog")
  (for-each clear! clear-targets)
  ;; (2) Source bootstrap (catalog absent -> source install + cross-compile).
  (info-msg "stage 2/4: source bootstrap (make wasm)")
  (mk)
  ;; (3) Strip the cross-compiled packages into the binary-only catalog.
  (info-msg "stage 3/4: build binary-only catalog (make wasm-binary-pkgs)")
  (mk #:target "wasm-binary-pkgs")
  ;; (4) Consume: clean-install from the catalog (catalog present -> .zo-only).
  (info-msg "stage 4/4: binary consume (make wasm)")
  (mk)

  (collect-outputs))

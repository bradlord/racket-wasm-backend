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

;; The strip (build-wasm-binary-pkgs.rkt) builds the binary catalog from
;; `installed-pkg-names`, which surfaces catalog-installed and in-tree static-root
;; packages but NOT the repo's local (path) packages (web-repl) -- so the binary
;; consume can't find them. After the strip, inject every `default-local-pkgs`
;; package into the catalog as source (they're tiny and pure; the consume's
;; `raco setup` compiles them for tpb32l alongside their now-present deps) and
;; rebuild the catalog index. See build-wasm.md "web-repl" / "Binary-only
;; package preload".
(define (inject-local-packages! racket)
  (define cache-pkgs (clone-path "racket" "src" ".wasm-pkgs-cache" "pkgs"))
  (define catalog (clone-path "racket" "src" ".wasm-pkgs-cache" "catalog"))
  (define names
    (for/list ([src (in-list default-local-pkgs)]
               #:when (directory-exists? src))
      (define name (path->string (file-name-from-path src)))
      (define dest (build-path cache-pkgs name))
      (when (directory-exists? dest) (delete-directory/files dest))
      ;; Source only (the repo copy has no compiled/, so dirs-catalog can load
      ;; each info.rkt on the host -- no tpb32l fasl-load trap).
      (copy-directory/files src dest)
      name))
  (when (pair? names)
    (info-msg "injecting local packages into binary catalog: ~a" names)
    ;; Rebuild the dirs-catalog over the full stripped tree + injected locals.
    ;; No --check-metadata: the strip's own packages (e.g. class-iop-lib) drop
    ;; their pkg-desc, and create-dirs-catalog (what the strip uses) doesn't
    ;; validate it either.
    (run racket #:dir clone-dir
         #:args (list "-l-" "pkg/dirs-catalog"
                      (path->string catalog) (path->string cache-pkgs)))))

;; opts: same shape as stages.rkt's `build` (pkgs/wasm-deps/scheme/racket).
(define (rebuild-binary-catalog opts)
  (define pkgs      (hash-ref opts 'pkgs (string-join default-pkgs " ")))
  (define wasm-deps (hash-ref opts 'wasm-deps default-wasm-deps))
  (unless (directory-exists? (build-path clone-dir ".git")) (sync))
  (apply-delta)
  (define scheme (resolve-host-scheme (hash-ref opts 'scheme #f)))
  (define racket (resolve-host-racket (hash-ref opts 'racket #f)))
  ;; Local (path) packages, --copy-installed by main.zuo in every stage: the
  ;; bootstrap installs them (so the strip catalogs them + their deps), the
  ;; consume re-installs them by --copy. They are NOT named PKGS, so without
  ;; this the binary image would drop them. See build-wasm.md "Local app
  ;; packages".
  (define local-pkgs
    (string-join (map (lambda (p) (path->string (path->complete-path p)))
                      default-local-pkgs)
                 " "))
  (define (mk #:target [t "wasm"])
    (make-wasm #:target t #:scheme scheme #:racket racket
               #:pkgs pkgs #:wasm-deps wasm-deps #:local-pkgs local-pkgs))

  ;; (1) Clear so the bootstrap builds a fresh *source* tree (the strip needs it).
  (info-msg "stage 1/4: clearing prior pkg tree + catalog")
  (for-each clear! clear-targets)
  ;; (2) Source bootstrap (catalog absent -> source install + cross-compile).
  (info-msg "stage 2/4: source bootstrap (make wasm)")
  (mk)
  ;; (3) Strip the cross-compiled packages into the binary-only catalog,
  ;;     then inject the repo's local packages (web-repl) the strip can't see.
  (info-msg "stage 3/4: build binary-only catalog (make wasm-binary-pkgs)")
  (mk #:target "wasm-binary-pkgs")
  (inject-local-packages! racket)
  ;; (4) Consume: clean-install from the catalog (catalog present -> .zo-only).
  (info-msg "stage 4/4: binary consume (make wasm)")
  (mk)

  (pack-share-data)
  (collect-outputs))

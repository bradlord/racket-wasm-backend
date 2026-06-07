#lang racket/base
;; `apply`: lay the port's delta onto a synced clone -- git-apply every
;; patches/**.patch, then copy overlay/ (incl. wasm-shell/) into the tree.
;;
;; Idempotent: it first restores the patched tracked files to the pin
;; (`git checkout -- <path>`) and re-copies overlay, so re-running after a prior
;; apply does not double-apply or fail. It does NOT git-clean the whole tree, so
;; build artifacts under .work survive a re-apply.
(require racket/file
         racket/path
         racket/string
         "config.rkt"
         "util.rkt")

(provide apply-delta patch-files patch->target)

;; All patch files under patches/, as absolute paths.
(define (patch-files)
  (sort
   (for/list ([p (in-directory patches-dir)]
              #:when (and (file-exists? p)
                          (regexp-match? #rx"\\.patch$" (path->string p))))
     p)
   string<? #:key path->string))

;; The clone-relative target path a patch modifies (patches/<rel>.patch -> <rel>).
(define (patch->target patch)
  (define rel (find-relative-path (path->complete-path patches-dir)
                                  (path->complete-path patch)))
  (define s (path->string rel))
  (substring s 0 (- (string-length s) (string-length ".patch"))))

(define (apply-delta #:check-only? [check-only? #f])
  (define patches (patch-files))
  (unless (directory-exists? (build-path clone-dir ".git"))
    (error 'apply "no clone at ~a -- run `sync` first" clone-dir))

  ;; 1. Restore the tracked files the patches touch, so a re-apply starts clean.
  (unless check-only?
    (for ([p (in-list patches)])
      (define target (patch->target p))
      (when (file-exists? (build-path clone-dir target))
        (git clone-dir "checkout" "--" target))))

  ;; 2. Apply each patch (or just check).
  (info-msg "~a ~a patches" (if check-only? "checking" "applying") (length patches))
  (for ([p (in-list patches)])
    (git clone-dir "apply" (if check-only? "--check" "--whitespace=nowarn")
         (path->string (path->complete-path p))))

  (unless check-only?
    ;; 3. Copy overlay/ then overlay-local/ into the clone root
    ;;    (<rel> -> clone/<rel>). overlay/ is fork-derived; overlay-local/ is
    ;;    repo-authored (the web-repl package). Content-aware copy preserves
    ;;    mtimes of unchanged files (see copy-tree).
    (info-msg "copying overlay + overlay-local into clone")
    (copy-tree overlay-dir clone-dir)
    (when (directory-exists? overlay-local-dir)
      (copy-tree overlay-local-dir clone-dir))
    (info-msg "delta applied")))

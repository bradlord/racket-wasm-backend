#lang racket/base
;; `sync`: materialize the pinned upstream Racket commit under .work/racket as a
;; clean, pristine tree. Uses a single-commit shallow fetch so we don't pull all
;; of upstream's history.
(require racket/file
         racket/path
         "config.rkt"
         "util.rkt")

(provide sync reset-to-pin!)

(define (cloned?)
  (directory-exists? (build-path clone-dir ".git")))

;; Fetch the pinned SHA (shallow) and hard-reset the tree to it, discarding all
;; local changes and untracked files (patches + overlay get re-applied by `apply`).
(define (reset-to-pin!)
  (info-msg "resetting clone to pinned ~a" (substring upstream-sha 0 12))
  (git clone-dir "reset" "--hard" upstream-sha)
  ;; Remove untracked (overlay copies, build artifacts). -x = include ignored;
  ;; -ff = also remove untracked dirs that contain nested git repos (meson wrap
  ;; checkouts like glib's subprojects/sysprof). A single -f skips those, which
  ;; leaves a gutted build-<dep>-em/src/ behind -- the dep recipe then sees the
  ;; dir, skips re-extracting the tarball, and fails at configure.
  (git clone-dir "clean" "-ffdx"))

(define (sync)
  (cond
    [(cloned?)
     (info-msg "fetching pin ~a from ~a" (substring upstream-sha 0 12) upstream-url)
     (git clone-dir "fetch" "--depth" "1" upstream-url upstream-sha)
     (git clone-dir "checkout" "--detach" upstream-sha)
     (reset-to-pin!)]
    [else
     (make-directory* clone-dir)
     (info-msg "initializing clone at ~a" clone-dir)
     (git clone-dir "init" "-q")
     (git clone-dir "fetch" "--depth" "1" upstream-url upstream-sha)
     (git clone-dir "checkout" "--detach" "FETCH_HEAD")])
  (info-msg "synced to pinned upstream commit"))

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
;; overlay/ is regenerated from the fork by extract-from-fork.rkt; overlay-local/
;; is repo-authored additive content NOT derived from the fork (e.g. the web-repl
;; package). Both are copied into the clone by `apply`; the extractor only
;; manages overlay/.
(define overlay-dir       (at-root "overlay"))
(define overlay-local-dir (at-root "overlay-local"))
;; Repo-side, NOT copied into the clone: host-side runtime glue (browser worker
;; bootstrap + dev server) and the page surfaces. The emcc link no longer stages
;; these; the orchestrator's collect-outputs copies them into dist/ directly, so
;; a surface can be swapped without touching the (expensive) link. See
;; build-wasm.md and the project roadmap.
(define runtime-glue-dir  (at-root "runtime-glue"))
(define surfaces-dir      (at-root "surfaces"))
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

;; Catalog packages cross-installed into the image (by name). List `-lib`
;; implementation packages, not metapackages (see build-wasm.md "Binary-only
;; package preload").
(define default-pkgs '("draw-lib" "datalog" "pict-lib"))

;; Local (path) packages the default IDE build ships, installed via
;; `raco pkg install --copy` (build/app.rkt `make-wasm-racket` #:local-pkgs).
;; web-repl is the WASM browser-surface helper collection; it lives in-repo at
;; packages/web-repl, NOT in the clone -- the clone stays pure upstream-delta.
(define default-local-pkgs (list (at-root "packages" "web-repl")))

;; Native C library deps. "draw" is the cairo/pango stack alias; libffi is
;; always built regardless.
(define default-wasm-deps "draw")

;; Host toolchains: overridable on the CLI. #f means "resolve/build".
(define default-host-scheme #f)   ; native *threaded* Chez (cross-compiler host)
(define default-host-racket #f)   ; same-version host Racket (raco cross-server)

;; The target Chez machine type for the WASM build.
(define target-machine "tpb32l")

;; What the emcc link + pack-share-data emit into the clone's wasm out dir -- the
;; runtime proper (the link products + the separate package payload). This is the
;; set the orchestrator copies into dist/ and caches per build-key. Glue/surface
;; are repo-side and copied separately, so they are NOT part of this set.
(define runtime-output-names
  '("scheme.js" "scheme.wasm" "scheme.data"
    "scheme-web.js" "scheme-web.wasm" "scheme-web.data"
    "share.data" "share.data.js"))

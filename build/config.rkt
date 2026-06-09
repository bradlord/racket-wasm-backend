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
;; bootstrap + dev server), copied into dist/ by the orchestrator's
;; collect-outputs so a surface can be swapped without touching the (expensive)
;; link. See build-wasm.md and the project roadmap.
(define runtime-glue-dir  (at-root "runtime-glue"))

;; The repo's canonical app: the DrRacket-like IDE / web-repl. `build` builds
;; this app (through the generic make-wasm-racket path -- it is the dogfood, not
;; a bespoke build), and the binary-catalog rebuild reads its package/dep set.
;; Its config lives in apps/ide/app.rkt; its page surface in apps/ide/public.
(define ide-app-dir (at-root "apps" "ide"))
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

;; --- build defaults -----------------------------------------------------
;;
;; The IDE app's package / native-dep / surface config lives in its manifest
;; (apps/ide/app.rkt), read via build/app.rkt `read-app-manifest` -- not here.
;; This keeps a single source of truth for what the default build ships.

;; Host toolchains: overridable on the CLI. #f means "resolve/build".
(define default-host-scheme #f)   ; native *threaded* Chez (cross-compiler host)
(define default-host-racket #f)   ; same-version host Racket (raco cross-server)

;; The target Chez machine type for the WASM build.
(define target-machine "tpb32l")

;; What the emcc link + pack-share-data emit into the clone's wasm out dir -- the
;; runtime proper (the link products + the separate package payload), split by
;; surface. The single `wasm` make target builds BOTH surfaces, so a build always
;; produces (and the cache always stores) the union; an app's `target` then
;; selects which subset collect-outputs copies into dist/.
;;   node    -- scheme.{js,wasm,data}; packages are baked into scheme.data.
;;   browser -- scheme-web.{js,wasm,data} + the separate package payload
;;              share.data/share.data.js (packed by file_packager, not the link).
;; Glue/surface are repo-side and copied separately, so they are NOT in this set.
(define node-runtime-names
  '("scheme.js" "scheme.wasm" "scheme.data"))
(define web-runtime-names
  '("scheme-web.js" "scheme-web.wasm" "scheme-web.data"
    "share.data" "share.data.js"))
;; The full set a build emits and the cache snapshots (both surfaces).
(define runtime-output-names (append node-runtime-names web-runtime-names))

;; An app's `target` field: which surface it runs on. Default is browser.
;; `web` is accepted as an alias for `browser`.
(define (normalize-target t)
  (define s (if (string? t) (string->symbol t) t))
  (case s
    [(browser web) 'browser]
    [(node) 'node]
    [else (error 'app "target must be 'browser or 'node, got: ~s" t)]))

;; The runtime files a given target ships in dist/.
(define (runtime-names-for-target target)
  (case (normalize-target target)
    [(node) node-runtime-names]
    [(browser) web-runtime-names]))
